using System.Diagnostics;

namespace AASwitch.Core;

/// <summary>正在运行的 Codex 进程（命令行、IDE 插件和桌面应用都会起 codex / codex-app-server）。切换要改会话记录，它们在跑就不能动。</summary>
public static class CodexProcesses
{
    static readonly string[] Names = ["codex", "codex-app-server"];

    public static IReadOnlyList<string> Running()
    {
        var found = new List<string>();
        foreach (var name in Names)
        {
            var ps = Process.GetProcessesByName(name);
            if (ps.Length > 0) found.Add($"{name} ×{ps.Length}");
            foreach (var p in ps) p.Dispose();
        }
        return found;
    }
}
