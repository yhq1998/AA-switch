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

    /// <summary>找 codex：环境变量 CODEX_BIN → PATH 里的 codex(.exe/.cmd)。找不到返回 null。</summary>
    public static string? Find()
    {
        var env = Environment.GetEnvironmentVariable("CODEX_BIN");
        if (!string.IsNullOrWhiteSpace(env)) return File.Exists(env) ? env : null;
        var names = OperatingSystem.IsWindows() ? new[] { "codex.exe", "codex.cmd" } : ["codex"];
        foreach (var dir in (Environment.GetEnvironmentVariable("PATH") ?? "").Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries))
            foreach (var name in names)
                try { var p = Path.Combine(dir.Trim('"'), name); if (File.Exists(p)) return p; } catch (ArgumentException) { }
        return null;
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
