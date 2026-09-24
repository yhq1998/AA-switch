using System.Diagnostics;
using Microsoft.Win32;

namespace AASwitch.Tray;

/// <summary>
/// 装到本机：从下载的地方直接双击运行时，提议把自己复制到 %LOCALAPPDATA%\Programs\AA Switch\，建开始菜单快捷方式、
/// 在“设置 → 应用”里登记（可以从那里卸载），然后从新位置重新打开。不装的话开始菜单里搜不到，
/// 挪动或删掉下载的文件后开机自启也会失效。和 Mac 版“在 dmg 里双击会提议装进应用程序”是同一件事。
/// </summary>
static class Installer
{
    public static string Dir { get; } = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Programs", AppInfo.Name);
    public static string InstalledExe { get; } = Path.Combine(Dir, AppInfo.Name + ".exe");
    static string ShortcutPath => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Programs), AppInfo.Name + ".lnk");
    const string UninstallKey = @"Software\Microsoft\Windows\CurrentVersion\Uninstall\AASwitch";

    public static bool IsInstalledCopy => string.Equals(Path.GetFullPath(AppInfo.ExePath), Path.GetFullPath(InstalledExe), StringComparison.OrdinalIgnoreCase);

    /// <summary>返回 true 表示已经装好并从新位置打开了，本进程应该退出。</summary>
    public static bool OfferInstall()
    {
        if (IsInstalledCopy) { Register(); return false; }   // 顺带补上被删掉的快捷方式、更新“应用”列表里的版本号
        if (string.Equals(Settings.InstallDeclined, AppInfo.ExePath, StringComparison.OrdinalIgnoreCase)) return false;
        Log.Write($"从安装目录以外启动：{AppInfo.ExePath}");
        var answer = MessageBox.Show(
            $"要把 {AppInfo.Name} 装到这台电脑上吗？\n\n装好后可以在开始菜单里搜到它，开机自启也不会因为挪动或删掉现在这个文件而失效。" +
            (IsInDownloads(AppInfo.ExePath) ? "“下载”里的这个文件会自动删掉。" : "") +
            "\n\n选“否”就从现在的位置运行，以后不再问。",
            AppInfo.Name, MessageBoxButtons.YesNo, MessageBoxIcon.Question);
        if (answer != DialogResult.Yes) { Settings.InstallDeclined = AppInfo.ExePath; Log.Write("用户选择不安装"); return false; }
        var failure = Install();
        if (failure is not null)
        {
            Log.Write("安装失败：" + failure);
            MessageBox.Show(failure + "\n\n这次先从现在的位置运行。", "没能安装", MessageBoxButtons.OK, MessageBoxIcon.Warning);
            return false;
        }
        Log.Write($"已装到 {InstalledExe}，从那里重新打开");
        Process.Start(new ProcessStartInfo(InstalledExe) { UseShellExecute = false, ArgumentList = { "--installed-from", AppInfo.ExePath } });
        return true;
    }

    /// <summary>复制到安装目录并登记；返回失败原因，成功为 null。已经在跑的旧版先关掉。</summary>
    public static string? Install()
    {
        foreach (var p in Process.GetProcessesByName(AppInfo.Name).Where(p => p.Id != Environment.ProcessId))
            try { p.Kill(); p.WaitForExit(5000); } catch (Exception e) when (e is InvalidOperationException or System.ComponentModel.Win32Exception) { }
        try
        {
            Directory.CreateDirectory(Dir);
            // 正在运行的 exe 不能覆盖但能改名：旧的先改成 .old（下次启动时删掉，见 SelfReplace.CleanUp）
            if (File.Exists(InstalledExe)) File.Move(InstalledExe, InstalledExe + ".old", overwrite: true);
            File.Copy(AppInfo.ExePath, InstalledExe);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { return "复制失败：" + e.Message; }
        Register();
        Autostart.PointTo(InstalledExe);
        return null;
    }

    /// <summary>开始菜单快捷方式 + “设置 → 应用”里的条目（卸载入口）。失败只记日志，不影响使用。</summary>
    static void Register()
    {
        try
        {
            if (!File.Exists(ShortcutPath))
            {
                var shell = Activator.CreateInstance(Type.GetTypeFromProgID("WScript.Shell")!)!;
                dynamic link = ((dynamic)shell).CreateShortcut(ShortcutPath);
                link.TargetPath = InstalledExe;
                link.WorkingDirectory = Dir;
                link.Description = "在账号和 API 之间切换 Codex / Claude Code";
                link.Save();
                Log.Write("已建开始菜单快捷方式：" + ShortcutPath);
            }
        }
        catch (Exception e) { Log.Write("建开始菜单快捷方式失败：" + e.Message); }
        try
        {
            using var k = Registry.CurrentUser.CreateSubKey(UninstallKey);
            k.SetValue("DisplayName", AppInfo.Name);
            k.SetValue("DisplayVersion", AppInfo.Version);
            k.SetValue("Publisher", AppInfo.Name);
            k.SetValue("DisplayIcon", InstalledExe);
            k.SetValue("InstallLocation", Dir);
            k.SetValue("UninstallString", $"\"{InstalledExe}\" --uninstall");
            k.SetValue("NoModify", 1, RegistryValueKind.DWord);
            k.SetValue("NoRepair", 1, RegistryValueKind.DWord);
            k.SetValue("EstimatedSize", (int)(new FileInfo(InstalledExe).Length / 1024), RegistryValueKind.DWord);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or System.Security.SecurityException) { Log.Write("登记卸载入口失败：" + e.Message); }
    }

    /// <summary>从“设置 → 应用”卸载：关掉程序、去掉开机自启、快捷方式和登记，程序退出后删掉安装目录。
    /// 已经切换好的 Codex / Claude Code 配置、保存的 key 和日志都不动。</summary>
    public static int Uninstall(bool quiet)
    {
        if (!quiet && MessageBox.Show($"卸载 {AppInfo.Name}？\n\nCodex 和 Claude Code 会保持现在的模式，保存的地址和 key 不会删除。",
                AppInfo.Name, MessageBoxButtons.OKCancel, MessageBoxIcon.Question) != DialogResult.OK) return 1;
        Log.Write("卸载");
        foreach (var p in Process.GetProcessesByName(AppInfo.Name).Where(p => p.Id != Environment.ProcessId))
            try { p.Kill(); p.WaitForExit(5000); } catch (Exception e) when (e is InvalidOperationException or System.ComponentModel.Win32Exception) { }
        Autostart.Enabled = false;
        try { File.Delete(ShortcutPath); } catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
        try { Registry.CurrentUser.DeleteSubKeyTree(UninstallKey, throwOnMissingSubKey: false); } catch (UnauthorizedAccessException) { }
        // 自己就在安装目录里，等退出后再删
        Process.Start(new ProcessStartInfo("cmd.exe", $"/c ping -n 3 127.0.0.1 >nul & rmdir /s /q \"{Dir}\"") { UseShellExecute = false, CreateNoWindow = true });
        return 0;
    }

    /// <summary>装好后新位置第一次启动时，把“下载”文件夹里的那份删掉（内容和自己一样才删）。原进程可能还没退干净，多试几次。</summary>
    public static void RemoveDownloadedCopy(string path)
    {
        if (!IsInDownloads(path) || !File.Exists(path)) return;
        Task.Run(async () =>
        {
            for (var i = 0; i < 10; i++)
            {
                try
                {
                    if (!File.ReadAllBytes(path).AsSpan().SequenceEqual(File.ReadAllBytes(AppInfo.ExePath))) return;
                    File.Delete(path);
                    Log.Write("已删除下载的安装文件：" + path);
                    return;
                }
                catch (Exception e) when (e is IOException or UnauthorizedAccessException) { await Task.Delay(1000); }
            }
        });
    }

    static bool IsInDownloads(string path)
    {
        var downloads = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "Downloads") + Path.DirectorySeparatorChar;
        return Path.GetFullPath(path).StartsWith(downloads, StringComparison.OrdinalIgnoreCase);
    }
}

/// <summary>再次打开时（已经有一个在跑），通知正在运行的那个把窗口弹出来，自己退出。</summary>
static class Reveal
{
    const string EventName = @"Local\AASwitch.Tray.Reveal";

    public static void Signal()
    {
        try { using var e = EventWaitHandle.OpenExisting(EventName); e.Set(); }
        catch (Exception e) when (e is WaitHandleCannotBeOpenedException or UnauthorizedAccessException or IOException) { }
    }

    public static void Listen(Action onSignal)
    {
        var e = new EventWaitHandle(false, EventResetMode.AutoReset, EventName);
        new Thread(() => { while (e.WaitOne()) onSignal(); }) { IsBackground = true, Name = "reveal" }.Start();
    }
}
