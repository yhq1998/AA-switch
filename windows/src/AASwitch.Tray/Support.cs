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
}

/// <summary>开机自启：当前用户的 Run 注册表项，不需要管理员权限，下次登录生效。</summary>
static class Autostart
{
    const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";

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
            if (value) k.SetValue(AppInfo.Name, $"\"{AppInfo.ExePath}\"");
            else k.DeleteValue(AppInfo.Name, throwOnMissingValue: false);
        }
    }
}
