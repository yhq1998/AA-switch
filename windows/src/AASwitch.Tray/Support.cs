using System.Reflection;
using System.Text;
using AASwitch.Core;
using Microsoft.Win32;

namespace AASwitch.Tray;

static class AppInfo
{
    public const string Name = "AA Switch";
    public static string Version => Assembly.GetExecutingAssembly().GetName().Version?.ToString(3) ?? "?";
    public static string DataDir { get; } = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), Name);
    public static string ExePath => Environment.ProcessPath ?? Application.ExecutablePath;

    /// <summary>官网 latest.json 的地址：构建时由 UPDATE_URL 写进程序集（见 build.sh）；环境变量 AASWITCH_UPDATE_URL 可覆盖，测试用。没设就不检查更新。</summary>
    public static string UpdateUrl
    {
        get
        {
            var env = Environment.GetEnvironmentVariable("AASWITCH_UPDATE_URL");
            if (!string.IsNullOrWhiteSpace(env)) return env;
            return Assembly.GetExecutingAssembly().GetCustomAttributes<AssemblyMetadataAttribute>().FirstOrDefault(a => a.Key == "UpdateUrl")?.Value ?? "";
        }
    }

    public static Icon LoadIcon(string resource, int size)
    {
        using var s = Assembly.GetExecutingAssembly().GetManifestResourceStream(resource) ?? throw new InvalidOperationException(resource);
        return new Icon(s, new Size(size, size));
    }
}

/// <summary>日志：%LOCALAPPDATA%\AA Switch\aa-switch.log，超过 1 MB 留后一半。导出诊断信息时带上最近 300 行。</summary>
static class Log
{
    static readonly object Gate = new();
    public static string FilePath { get; } = Path.Combine(AppInfo.DataDir, "aa-switch.log");

    public static void Write(string message)
    {
        lock (Gate)
            try
            {
                Directory.CreateDirectory(AppInfo.DataDir);
                var f = new FileInfo(FilePath);
                if (f.Exists && f.Length > 1_000_000)
                {
                    var lines = File.ReadAllLines(FilePath, Encoding.UTF8);
                    File.WriteAllLines(FilePath, lines[(lines.Length / 2)..], new UTF8Encoding(false));
                }
                File.AppendAllText(FilePath, $"{DateTime.Now:yyyy-MM-dd HH:mm:ss} {message}\n", new UTF8Encoding(false));
            }
            catch (IOException) { } catch (UnauthorizedAccessException) { }
    }

    public static string Tail(int lines)
    {
        try { return string.Join("\n", File.ReadLines(FilePath, Encoding.UTF8).TakeLast(lines)); }
        catch (IOException) { return "（读不到日志）"; }
    }
}

/// <summary>程序自己的少量设置（是否做过初始设置），和日志放在一起。</summary>
static class Settings
{
    static readonly ConfFile Conf = new(Path.Combine(AppInfo.DataDir, "settings.conf"));
    public static bool OnboardingDone { get => Conf.Get("onboarding_done") == "1"; set => Conf.Set("onboarding_done", value ? "1" : "0"); }
    /// <summary>用户说过“不安装”的那个 exe 路径：从这里再打开时不再问。</summary>
    public static string InstallDeclined { get => Conf.Get("install_declined"); set => Conf.Set("install_declined", value); }
}

/// <summary>开机自启：当前用户的 Run 注册表项，不需要管理员权限，下次登录生效。
/// 带 --autostart 参数：开机时安静地待在托盘，不弹窗口，也不提议安装。</summary>
static class Autostart
{
    const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    static string Command(string exe) => $"\"{exe}\" --autostart";

    /// <summary>开着自启时改成指向 exe（装到本机后用）。</summary>
    public static void PointTo(string exe)
    {
        using var k = Registry.CurrentUser.OpenSubKey(RunKey, writable: true);
        if (k?.GetValue(AppInfo.Name) is string s && s != Command(exe)) { k.SetValue(AppInfo.Name, Command(exe)); Log.Write($"开机自启：{s} → {Command(exe)}"); }
    }

    /// <summary>启动时修正：记下的程序已经不在了（被挪走或删掉）就改成自己；指向自己但没带 --autostart（旧版写的）就补上。</summary>
    public static void Repair()
    {
        using var k = Registry.CurrentUser.OpenSubKey(RunKey);
        if (k?.GetValue(AppInfo.Name) is not string s) return;
        var target = s.StartsWith('"') ? s[1..s.IndexOf('"', 1)] : s.Split(' ')[0];
        if (!File.Exists(target) || string.Equals(target, AppInfo.ExePath, StringComparison.OrdinalIgnoreCase)) PointTo(AppInfo.ExePath);
    }

    public static bool Enabled
    {
        get
        {
            using var k = Registry.CurrentUser.OpenSubKey(RunKey);
            return k?.GetValue(AppInfo.Name) is string s && s.Contains(AppInfo.ExePath, StringComparison.OrdinalIgnoreCase);
        }
        set
        {
            using var k = Registry.CurrentUser.CreateSubKey(RunKey);
            if (value) k.SetValue(AppInfo.Name, Command(AppInfo.ExePath));
            else k.DeleteValue(AppInfo.Name, throwOnMissingValue: false);
        }
    }
}

/// <summary>
/// 应用内更新的最后一步：用下载好的新 exe 换掉自己。Windows 允许给正在运行的 exe 改名，所以先把自己改名成 .old，
/// 再把新的放到原位置；第二步失败就把名字改回来，现有安装不受影响。.old 在下次启动时删掉。
/// </summary>
static class SelfReplace
{
    static string OldPath => AppInfo.ExePath + ".old";

    public static void Swap(string newExe)
    {
        var exe = AppInfo.ExePath;
        try { File.Delete(OldPath); } catch (IOException) { } catch (UnauthorizedAccessException) { }
        try { File.Move(exe, OldPath, overwrite: true); }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { throw new SwitchException($"没有权限替换 {exe}：{e.Message}"); }
        try { File.Move(newExe, exe); }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            File.Move(OldPath, exe);
            throw new SwitchException($"放入新版本失败：{e.Message}");
        }
    }

    public static void CleanUp()
    {
        try { File.Delete(OldPath); } catch (IOException) { } catch (UnauthorizedAccessException) { }
    }
}
