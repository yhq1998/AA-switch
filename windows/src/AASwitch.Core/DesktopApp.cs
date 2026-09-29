using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;

namespace AASwitch.Core;

/// <summary>退出、打开 Claude 桌面应用。单测里换成假的。</summary>
public interface IDesktopApp
{
    bool Running();
    /// <summary>退出应用，退不掉抛 SwitchException。</summary>
    void Quit();
    void Open();
}

/// <summary>
/// Windows 上的 Claude 桌面应用进程。进程名是 claude.exe，但 Claude Code 命令行的原生版也叫 claude.exe，
/// 所以按程序位置认：应用商店版在 …\WindowsApps\Claude_…\，安装包版在 %LOCALAPPDATA%\AnthropicClaude\ 下。
/// 关窗口只会缩到托盘，所以先请它关窗口，等不到就结束整个进程树（配置在退出之后才写，不怕它退出时写回旧设置）。
/// </summary>
public sealed class WindowsDesktopApp(ClaudeDesktopPaths dp) : IDesktopApp
{
    public static bool IsDesktopImage(string path, ClaudeDesktopPaths dp) =>
        path.Contains(@"\WindowsApps\Claude_", StringComparison.OrdinalIgnoreCase) ||
        path.StartsWith(dp.InstallerDir + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase);

    List<Process> Find()
    {
        var found = new List<Process>();
        foreach (var p in Process.GetProcessesByName("claude"))
        {
            var image = ImagePath(p.Id);
            if (image is not null && IsDesktopImage(image, dp)) found.Add(p);
            else p.Dispose();
        }
        return found;
    }

    /// <summary>诊断信息用：每个桌面应用进程的 pid 和位置。</summary>
    public List<string> Describe()
    {
        var ps = Find();
        var lines = ps.Select(p => $"{p.Id} {ImagePath(p.Id)}").ToList();
        foreach (var p in ps) p.Dispose();
        return lines;
    }

    public bool Running()
    {
        var ps = Find();
        foreach (var p in ps) p.Dispose();
        return ps.Count > 0;
    }

    public void Quit()
    {
        var ps = Find();
        try
        {
            foreach (var p in ps) try { p.CloseMainWindow(); } catch (InvalidOperationException) { }
            if (WaitAll(ps, TimeSpan.FromSeconds(3))) return;
            foreach (var p in ps)
                try { if (!p.HasExited) p.Kill(entireProcessTree: true); }
                catch (Exception e) when (e is Win32Exception or InvalidOperationException or NotSupportedException) { }
            WaitAll(ps, TimeSpan.FromSeconds(10));
        }
        finally { foreach (var p in ps) p.Dispose(); }
        if (Running()) throw new SwitchException("Claude 桌面应用没有退出，请在任务栏右下角的托盘里右键 Claude 选“退出”，再切换一次。");
        Thread.Sleep(500);   // 让它把文件句柄放掉
    }

    static bool WaitAll(List<Process> ps, TimeSpan timeout)
    {
        var end = DateTime.UtcNow + timeout;
        foreach (var p in ps)
        {
            var left = end - DateTime.UtcNow;
            try { if (left <= TimeSpan.Zero ? !p.HasExited : !p.WaitForExit(left)) return false; }
            catch (InvalidOperationException) { }
        }
        return true;
    }

    /// <summary>进程的程序位置。只要“有限查询”权限，应用商店版的进程也读得到（Process.MainModule 要读进程内存，可能被拒）。</summary>
    static string? ImagePath(int pid)
    {
        if (!OperatingSystem.IsWindows()) return null;
        var h = OpenProcess(0x1000 /* PROCESS_QUERY_LIMITED_INFORMATION */, false, pid);
        if (h == IntPtr.Zero) return null;
        try
        {
            var buf = new StringBuilder(1024);
            var size = buf.Capacity;
            return QueryFullProcessImageName(h, 0, buf, ref size) ? buf.ToString(0, size) : null;
        }
        finally { CloseHandle(h); }
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern IntPtr OpenProcess(uint access, bool inherit, int pid);
    [DllImport("kernel32.dll", EntryPoint = "QueryFullProcessImageNameW", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool QueryFullProcessImageName(IntPtr process, uint flags, StringBuilder name, ref int size);
    [DllImport("kernel32.dll")]
    static extern bool CloseHandle(IntPtr handle);

    public void Open()
    {
        if (dp.PackageFamily is { } pfn)
        {
            Process.Start(new ProcessStartInfo("explorer.exe", $@"shell:AppsFolder\{pfn}!Claude") { UseShellExecute = false })?.Dispose();
            return;
        }
        var exe = Path.Combine(dp.InstallerDir, "claude.exe");
        if (!File.Exists(exe)) throw new SwitchException("找不到 Claude 桌面应用的程序。");
        Process.Start(new ProcessStartInfo(exe) { UseShellExecute = true })?.Dispose();
    }
}
