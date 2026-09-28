using System.Diagnostics;

namespace AASwitch.Core;

/// <summary>调用 Codex 自己的命令行：查登录态、用 key 登录、登出。登录态让 Codex 自己写，我们不猜 auth.json 的格式。</summary>
public interface ICodexCli
{
    /// <summary>codex login status 的完整输出（标准输出 + 错误输出）。</summary>
    string LoginStatus();
    bool LoginWithApiKey(string key);
    void Logout();
}

public sealed class CodexCli(string executable, string codexHome) : ICodexCli
{
    public string Executable { get; } = executable;

    /// <summary>找 codex 的结果：找到的路径（没找到是 null），和找过哪些位置——没找到时要摆给用户看。</summary>
    public sealed record Lookup(string? Path, IReadOnlyList<string> Tried);

    /// <summary>找 codex：调用方存下来的位置（托盘里用户自己指的）→ 环境变量 CODEX_BIN → Codex 桌面应用自带的那份
    /// → PATH 里的 codex(.exe/.cmd/.bat) → 常见的安装位置（npm 全局、winget、pnpm、Scoop，这几处经常不在 PATH 里）。
    /// 指定的位置文件不在了就当没设，接着往下找，并记进 Tried。
    /// 环境变量和 PATH 在 Windows 上另外读当前用户和本机的那两份：进程里的是启动那一刻的快照，用户装完 codex 或
    /// setx 之后不重启程序就一直看不到，注册表里的那两份是实时的。</summary>
    public static Lookup Locate(string? configured = null)
    {
        var tried = new List<string>();
        var names = OperatingSystem.IsWindows() ? new[] { "codex.exe", "codex.cmd", "codex.bat" } : ["codex"];

        static bool Exists(string p) { try { return File.Exists(p); } catch (ArgumentException) { return false; } catch (IOException) { return false; } }

        string? Explicit(string? path, string how)
        {
            if (string.IsNullOrWhiteSpace(path)) return null;
            path = path.Trim().Trim('"');
            if (Exists(path)) return path;
            tried.Add($"{how}：{path}（这个文件不在了）");
            return null;
        }

        var found = Explicit(configured, "在 AA Switch 里指定的位置");
        if (found is not null) return new Lookup(found, tried);
        foreach (var v in EnvValues("CODEX_BIN"))
            if ((found = Explicit(v, "环境变量 CODEX_BIN")) is not null) return new Lookup(found, tried);

        // Codex 桌面应用（应用商店版）每次启动把自带的 codex.exe 从安装包复制到 %LOCALAPPDATA%\OpenAI\Codex\bin\<运行时 ID>\ 下，
        // 这个目录不在 PATH 里。只装了桌面应用、没另装命令行的用户靠这一条。排在 PATH 前面，和应用用的是同一个版本
        if ((found = FromCodexApp(tried)) is not null) return new Lookup(found, tried);

        var seen = new HashSet<string>(OperatingSystem.IsWindows() ? StringComparer.OrdinalIgnoreCase : StringComparer.Ordinal);
        string? InDir(string dir, string how)
        {
            dir = dir.Trim().Trim('"');
            if (dir.Length == 0 || !seen.Add(dir)) return null;
            if (IsStorePackageDir(dir)) { tried.Add($"{how} {dir}（应用商店的安装目录，里面的程序不能直接运行，跳过）"); return null; }
            foreach (var name in names)
            {
                string p;
                try { p = Path.Combine(dir, name); } catch (ArgumentException) { break; }
                if (Exists(p)) return p;
            }
            tried.Add($"{how} {dir}");
            return null;
        }
        foreach (var dir in EnvValues("PATH").SelectMany(v => v.Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries)))
            if ((found = InDir(dir, "PATH 里的")) is not null) return new Lookup(found, tried);
        foreach (var (how, dir) in KnownInstallDirs())
            if ((found = InDir(dir, how)) is not null) return new Lookup(found, tried);
        return new Lookup(null, tried);
    }

    /// <summary>%LOCALAPPDATA%\OpenAI\Codex\bin 下的 codex.exe（直接在 bin 里，或在某个运行时 ID 的子目录里），有几份取最新的。</summary>
    static string? FromCodexApp(List<string> tried)
    {
        var local = KnownFolder("LOCALAPPDATA", Environment.SpecialFolder.LocalApplicationData);
        if (local is null) return null;
        var bin = Path.Combine(local, "OpenAI", "Codex", "bin");
        try
        {
            if (Directory.Exists(bin))
            {
                var best = Directory.EnumerateDirectories(bin).Prepend(bin)
                    .Select(d => new FileInfo(Path.Combine(d, "codex.exe")))
                    .Where(f => f.Exists)
                    .OrderByDescending(f => f.LastWriteTimeUtc)
                    .FirstOrDefault();
                if (best is not null) return best.FullName;
            }
        }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
        tried.Add($"Codex 桌面应用自带的 {bin}（没有；装了桌面应用的话先打开它一次）");
        return null;
    }

    /// <summary>常用安装方式放 codex 的目录，经常没进 PATH（或者进了但程序启动时还没有）。</summary>
    static IEnumerable<(string How, string Dir)> KnownInstallDirs()
    {
        var roaming = KnownFolder("APPDATA", Environment.SpecialFolder.ApplicationData);
        var local = KnownFolder("LOCALAPPDATA", Environment.SpecialFolder.LocalApplicationData);
        var home = KnownFolder("USERPROFILE", Environment.SpecialFolder.UserProfile);
        if (roaming is not null) yield return ("npm 全局安装的", Path.Combine(roaming, "npm"));
        if (local is not null) yield return ("winget 安装的", Path.Combine(local, "Microsoft", "WinGet", "Links"));
        if (local is not null) yield return ("pnpm 安装的", Path.Combine(local, "pnpm"));
        if (home is not null) yield return ("Scoop 安装的", Path.Combine(home, "scoop", "shims"));
    }

    /// <summary>Windows 的用户目录：先看环境变量（测试里可以指到临时目录），没有再问系统。别的系统上只认环境变量。</summary>
    static string? KnownFolder(string env, Environment.SpecialFolder folder)
    {
        var v = Environment.GetEnvironmentVariable(env);
        if (!string.IsNullOrWhiteSpace(v)) return v;
        if (!OperatingSystem.IsWindows()) return null;
        var f = Environment.GetFolderPath(folder);
        return string.IsNullOrEmpty(f) ? null : f;
    }

    /// <summary>应用商店的安装目录（…\WindowsApps\包名\…）：里面的 codex.exe 有权限限制，直接运行报“拒绝访问”。
    /// %LOCALAPPDATA%\Microsoft\WindowsApps 是应用执行别名的目录，那里的能运行，不算。</summary>
    static bool IsStorePackageDir(string dir)
    {
        var parts = dir.Split('\\', '/');
        for (var i = 0; i < parts.Length - 1; i++)
            if (parts[i].Equals("WindowsApps", StringComparison.OrdinalIgnoreCase) && !(i > 0 && parts[i - 1].Equals("Microsoft", StringComparison.OrdinalIgnoreCase)))
                return true;
        return false;
    }

    /// <summary>找 codex，只要路径。找不到返回 null。</summary>
    public static string? Find(string? configured = null) => Locate(configured).Path;

    /// <summary>一个环境变量的几种来源，按优先级：当前进程 → 当前用户 → 本机。后两份在 Windows 上查的是注册表，实时。</summary>
    static IEnumerable<string> EnvValues(string name)
    {
        var values = new List<string?> { Environment.GetEnvironmentVariable(name) };
        if (OperatingSystem.IsWindows())
        {
            values.Add(Environment.GetEnvironmentVariable(name, EnvironmentVariableTarget.User));
            values.Add(Environment.GetEnvironmentVariable(name, EnvironmentVariableTarget.Machine));
        }
        return values.OfType<string>().Where(v => v.Trim().Length > 0).Distinct(StringComparer.Ordinal);
    }

    (int Code, string Output) Run(string[] args, string? stdin = null)
    {
        var psi = new ProcessStartInfo
        {
            RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true,
            UseShellExecute = false, CreateNoWindow = true,
        };
        // npm 装的 codex 在 Windows 上是 codex.cmd，批处理要经 cmd.exe 才能启动；参数都是固定的单词，不涉及引号转义
        if (OperatingSystem.IsWindows() && Path.GetExtension(Executable).ToLowerInvariant() is ".cmd" or ".bat")
        {
            psi.FileName = Environment.GetEnvironmentVariable("ComSpec") ?? "cmd.exe";
            psi.Arguments = $"/d /s /c \"\"{Executable}\" {string.Join(' ', args)}\"";
        }
        else
        {
            psi.FileName = Executable;
            foreach (var a in args) psi.ArgumentList.Add(a);
        }
        psi.Environment["CODEX_HOME"] = codexHome;
        using var p = Process.Start(psi) ?? throw new SwitchException($"无法启动 {Executable}。");
        var stdout = p.StandardOutput.ReadToEndAsync();
        var stderr = p.StandardError.ReadToEndAsync();
        if (stdin is not null) p.StandardInput.Write(stdin);
        p.StandardInput.Close();
        if (!p.WaitForExit(60_000)) { try { p.Kill(entireProcessTree: true); } catch (InvalidOperationException) { } throw new SwitchException("codex 命令 60 秒没有返回。"); }
        return (p.ExitCode, stdout.Result + stderr.Result);
    }

    public string LoginStatus() => Run(["login", "status"]).Output;
    public bool LoginWithApiKey(string key) => Run(["login", "--with-api-key"], key).Code == 0;
    public void Logout() => Run(["logout"]);
}

/// <summary>找不到 codex 命令行。托盘程序会专门接住它（重新找一遍、让用户自己指位置），所以单独一个类型。</summary>
public sealed class CodexNotFoundException(string message) : SwitchException(message);
