using System.Text;
using System.Text.RegularExpressions;
using Microsoft.Data.Sqlite;

namespace AASwitch.Core;

/// <summary>
/// Codex 的历史会话：每条会话把创建时的 provider 名记在两处——会话文件（sessions/**/*.jsonl 第一行的 session_meta）和
/// 状态库（state_*.sqlite 的 threads.model_provider）。这里负责列出出现过的名字、把记成 openai 的改记为默认 provider，
/// 以及这些文件的备份和恢复。Windows 没有自带 sqlite3，所以用程序自带的 SQLite。
/// </summary>
public sealed partial class CodexSessions(string codexHome)
{
    static readonly string[] SessionDirs = ["sessions", "archived_sessions"];
    static readonly UTF8Encoding Utf8 = new(false);

    IEnumerable<string> SessionFiles() => SessionDirs
        .Select(d => Path.Combine(codexHome, d)).Where(Directory.Exists)
        .SelectMany(d => Directory.EnumerateFiles(d, "*.jsonl", SearchOption.AllDirectories));

    public IEnumerable<string> StateDbs() => Directory.Exists(codexHome)
        ? Directory.EnumerateFiles(codexHome, "state_*.sqlite").OrderBy(p => p, StringComparer.Ordinal) : [];

    // Pooling=False：用完立刻放开文件；连接池会一直占着库文件，Windows 上之后的复制、恢复都会因为文件被占用而失败
    static SqliteConnection Open(string db, bool readOnly = false)
    {
        var c = new SqliteConnection(new SqliteConnectionStringBuilder
        {
            DataSource = db, Pooling = false, DefaultTimeout = 5,
            Mode = readOnly ? SqliteOpenMode.ReadOnly : SqliteOpenMode.ReadWrite,
        }.ToString());
        c.Open();
        using var busy = c.CreateCommand(); busy.CommandText = "pragma busy_timeout=5000"; busy.ExecuteNonQuery();
        return c;
    }

    /// <summary>读文件第一行（不含换行），同时返回第一个换行符的字节位置；没有换行时为 -1。</summary>
    static string FirstLine(string path, out long newlineAt)
    {
        using var fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite);
        using var ms = new MemoryStream();
        var buf = new byte[65536];
        int n;
        while ((n = fs.Read(buf, 0, buf.Length)) > 0)
        {
            var nl = Array.IndexOf(buf, (byte)'\n', 0, n);
            if (nl >= 0) { ms.Write(buf, 0, nl); newlineAt = ms.Length; return Utf8.GetString(ms.ToArray()); }
            ms.Write(buf, 0, n);
        }
        newlineAt = -1;
        return Utf8.GetString(ms.ToArray());
    }

    /// <summary>历史会话里出现过的 provider 名（状态库 + 会话文件首行），读不了的库或文件跳过。</summary>
    public List<string> HistoryProviders()
    {
        var names = new List<string>();
        foreach (var db in StateDbs())
            try
            {
                using var c = Open(db, readOnly: true);
                using var cmd = c.CreateCommand();
                cmd.CommandText = "select distinct model_provider from threads where model_provider is not null and model_provider != ''";
                using var r = cmd.ExecuteReader();
                while (r.Read()) names.Add(r.GetString(0));
            }
            catch (SqliteException) { }
        foreach (var f in SessionFiles())
            try
            {
                var m = ProviderField().Match(FirstLine(f, out _));
                if (m.Success) names.Add(m.Groups[1].Value);
            }
            catch (IOException) { }
        return names;
    }

    public int CountOpenAiThreads()
    {
        var n = 0;
        foreach (var db in StateDbs())
            try
            {
                using var c = Open(db, readOnly: true);
                using var cmd = c.CreateCommand();
                cmd.CommandText = "select count(*) from threads where model_provider='openai'";
                n += Convert.ToInt32(cmd.ExecuteScalar());
            }
            catch (SqliteException) { }
        return n;
    }

    /// <summary>把记成 openai 的会话改记为 provider：会话文件只改第一行，状态库改 threads 表；每个文件改前先备份。返回改动处数。</summary>
    public int FixThreads(string provider, CodexBackup backup)
    {
        var n = 0;
        const string from = "\"model_provider\":\"openai\"";
        foreach (var f in SessionFiles().ToList())
        {
            var first = FirstLine(f, out var newlineAt);
            if (!first.Contains("\"type\":\"session_meta\"", StringComparison.Ordinal)) continue;
            var at = first.IndexOf(from, StringComparison.Ordinal);
            if (at < 0) continue;
            backup.File(f);
            var tmp = f + ".aaswitch-tmp";
            try
            {
                using (var src = new FileStream(f, FileMode.Open, FileAccess.Read, FileShare.Read))
                using (var dst = new FileStream(tmp, FileMode.Create, FileAccess.Write, FileShare.None))
                {
                    dst.Write(Utf8.GetBytes(first[..at] + $"\"model_provider\":\"{provider}\"" + first[(at + from.Length)..]));
                    if (newlineAt >= 0) { src.Position = newlineAt; src.CopyTo(dst); }   // 从换行符开始原样复制
                }
                var times = (File.GetCreationTimeUtc(f), File.GetLastWriteTimeUtc(f));
                File.Move(tmp, f, overwrite: true);
                File.SetCreationTimeUtc(f, times.Item1); File.SetLastWriteTimeUtc(f, times.Item2);   // Codex 按修改时间排会话，别把旧会话顶到最前
            }
            finally { if (File.Exists(tmp)) File.Delete(tmp); }
            n++;
        }
        foreach (var db in StateDbs().ToList())
        {
            backup.Database(db);
            using var c = Open(db);
            using var cmd = c.CreateCommand();
            cmd.CommandText = "update threads set model_provider=$p where model_provider='openai'";
            cmd.Parameters.AddWithValue("$p", provider);
            n += cmd.ExecuteNonQuery();
        }
        return n;
    }

    /// <summary>用 SQLite 自己的在线备份拿一致快照（包含 WAL 里已提交的内容），副本改成没有边车文件的模式。</summary>
    public static void BackupDatabase(string source, string dest)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(dest)!);
        if (File.Exists(dest)) File.Delete(dest);
        using (var src = Open(source, readOnly: true))
        using (var dst = new SqliteConnection(new SqliteConnectionStringBuilder { DataSource = dest, Pooling = false }.ToString()))
        {
            dst.Open();
            src.BackupDatabase(dst);
            using var cmd = dst.CreateCommand(); cmd.CommandText = "pragma journal_mode=delete"; cmd.ExecuteScalar();
        }
    }

    /// <summary>把备份的库内容倒回原库（相当于 sqlite3 的 .restore），原库的 WAL 由 SQLite 自己处理。</summary>
    public static void RestoreDatabase(string backupFile, string target)
    {
        using var src = Open(backupFile, readOnly: true);
        using var dst = new SqliteConnection(new SqliteConnectionStringBuilder { DataSource = target, Pooling = false, DefaultTimeout = 5 }.ToString());
        dst.Open();
        src.BackupDatabase(dst);
    }

    [GeneratedRegex("\"model_provider\":\"([^\"]*)\"")]
    private static partial Regex ProviderField();
}

/// <summary>一次切换的备份目录 codex-mode-backups/&lt;时间&gt;/，里面按相对 CODEX_HOME 的路径存放；恢复时原路放回。</summary>
public sealed class CodexBackup(string codexHome, string dir)
{
    public string Dir { get; } = dir;

    string Dest(string path) => Path.Combine(Dir, Path.GetRelativePath(codexHome, path));

    public void File(string path)
    {
        if (!System.IO.File.Exists(path)) return;
        var dest = Dest(path);
        Directory.CreateDirectory(Path.GetDirectoryName(dest)!);
        System.IO.File.Copy(path, dest, overwrite: true);
    }

    public void Database(string path) => CodexSessions.BackupDatabase(path, Dest(path));

    public void RestoreAll()
    {
        if (!Directory.Exists(Dir)) return;
        foreach (var f in Directory.EnumerateFiles(Dir, "*", SearchOption.AllDirectories))
        {
            var target = Path.Combine(codexHome, Path.GetRelativePath(Dir, f));
            if (f.EndsWith(".sqlite-wal", StringComparison.Ordinal) || f.EndsWith(".sqlite-shm", StringComparison.Ordinal) || f.EndsWith(".sqlite-journal", StringComparison.Ordinal)) continue;
            if (f.EndsWith(".sqlite", StringComparison.Ordinal)) CodexSessions.RestoreDatabase(f, target);
            else { Directory.CreateDirectory(Path.GetDirectoryName(target)!); System.IO.File.Copy(f, target, overwrite: true); }
        }
    }
}
