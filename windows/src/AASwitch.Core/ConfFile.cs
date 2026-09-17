using System.Text;

namespace AASwitch.Core;

/// <summary>key=value 配置文件，格式与 macOS 脚本的 claude-mode.conf / codex-mode.conf 相同。</summary>
public sealed class ConfFile(string path)
{
    public string FilePath { get; } = path;

    public string Get(string key)
    {
        if (!File.Exists(FilePath)) return "";
        var prefix = key + "=";
        foreach (var line in File.ReadLines(FilePath, Encoding.UTF8))
            if (line.StartsWith(prefix, StringComparison.Ordinal)) return line[prefix.Length..];
        return "";
    }

    public void Set(string key, string value)
    {
        var prefix = key + "=";
        var lines = File.Exists(FilePath)
            ? File.ReadAllLines(FilePath, Encoding.UTF8).Where(l => !l.StartsWith(prefix, StringComparison.Ordinal)).ToList()
            : [];
        lines.Add(prefix + value);
        AtomicFile.WriteAllText(FilePath, string.Join("\n", lines) + "\n");
    }
}

public static class AtomicFile
{
    static readonly UTF8Encoding Utf8NoBom = new(false);

    /// <summary>先写同目录的临时文件再改名，写到一半断电也不会留下半个文件。</summary>
    public static void WriteAllText(string path, string text)
    {
        var dir = Path.GetDirectoryName(path)!;
        Directory.CreateDirectory(dir);
        var tmp = Path.Combine(dir, "." + Path.GetFileName(path) + "." + Guid.NewGuid().ToString("N")[..8] + ".tmp");
        try
        {
            File.WriteAllText(tmp, text, Utf8NoBom);
            File.Move(tmp, path, overwrite: true);
        }
        finally { if (File.Exists(tmp)) File.Delete(tmp); }
    }
}
