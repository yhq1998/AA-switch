using System.Drawing.Imaging;
using AASwitch.Core;
using AASwitch.Tray;

// AA Switch 托盘程序。不带参数：常驻托盘（只允许一个实例）。
//   --click <codex|claude> <api|account>   不显示界面，走一遍点击分段控件后的切换流程然后退出（退出码 0 表示成功）。给 CI 用。
//   --update-now      不显示界面，查一次更新，有新版就下载、校验并替换自己然后退出（不重新打开）。给 CI 用。
//   --after-update    应用内更新后由旧版本启动新版本时带的参数：等旧版本退出后再常驻。
//   --render <目录> --demo   同上，但用一套固定的演示数据（README 里的截图就是这么出的），不读真实配置。
//   --render <目录>   把菜单、窗口、配置表单和初始设置画成 PNG 存到目录里然后退出。给 CI 用：没有人盯着 Windows 屏幕时也能看到界面长什么样。
//   --autostart       开机自启（Run 注册表项）带的参数：安静地待在托盘，不弹窗口、不提议安装。
//   --install         不问，直接装到 %LOCALAPPDATA%\Programs\AA Switch（开始菜单快捷方式、“设置 → 应用”里的条目）然后退出。
//   --uninstall [--quiet]   “设置 → 应用”里点卸载时执行的。
//   --installed-from <路径>  装好后新位置第一次启动时带的：删掉“下载”里的那份。
// 不带这些参数（用户自己双击打开）：从安装目录以外打开时先提议安装；已经有一个在跑就让它弹出窗口；否则常驻托盘并弹出窗口。
static class Program
{
    [STAThread]
    static int Main(string[] args)
    {
        ApplicationConfiguration.Initialize();
        if (args.Length is 2 or 3 && args[0] == "--render") return Render(args[1], demo: args.Contains("--demo"));
        if (args.Length == 3 && args[0] == "--click") return Click(args[1], args[2] == "api");
        if (args.Length == 1 && args[0] == "--update-now") return Headless(app => app.UpdateForTestAsync(), "--update-now");

        if (args.Length == 1 && args[0] == "--install") { var failure = Installer.Install(); Console.WriteLine(failure ?? "installed " + Installer.InstalledExe); return failure is null ? 0 : 1; }
        if (args.Length >= 1 && args[0] == "--uninstall") return Installer.Uninstall(quiet: args.Contains("--quiet"));
        var afterUpdate = args.Contains("--after-update");
        var quiet = afterUpdate || args.Contains("--autostart");
        // 要放在单实例检查前面：拿新下载的版本覆盖安装时，得先把正在运行的旧版关掉
        if (!quiet && Installer.OfferInstall()) return 0;

        using var single = new Mutex(false, @"Local\AASwitch.Tray");
        // 已经有一个在跑：让它把窗口弹出来（多半是图标被收进了任务栏的“^”里，用户以为没开），自己退出。
        // 更新后重新打开时旧版本可能还没退干净，多等一会儿
        try { if (!single.WaitOne(afterUpdate ? 15_000 : 0)) { if (!quiet) Reveal.Signal(); return 0; } } catch (AbandonedMutexException) { }
        var from = Array.IndexOf(args, "--installed-from");
        if (from >= 0 && from + 1 < args.Length) Installer.RemoveDownloadedCopy(args[from + 1]);
        Application.ThreadException += (_, e) => { Log.Write("未处理的异常：" + e.Exception); MessageBox.Show(e.Exception.Message, AppInfo.Name, MessageBoxButtons.OK, MessageBoxIcon.Warning); };
        Application.Run(new TrayApp(showWindow: !quiet));
        return 0;
    }

    static int Click(string product, bool toApi) => Headless(app => app.ClickForTestAsync(product, toApi), $"--click {product} {(toApi ? "api" : "account")}");

    /// <summary>不显示界面跑一个操作：需要消息循环（切换和更新都会回到界面线程），做完就退出。</summary>
    static int Headless(Func<TrayApp, Task<string?>> action, string what)
    {
        using var app = new TrayApp(renderOnly: true);
        string? error = "没有完成";
        action(app).ContinueWith(t => { error = t.IsFaulted ? t.Exception!.GetBaseException().Message : t.Result; Application.ExitThread(); }, TaskScheduler.FromCurrentSynchronizationContext());
        Application.Run();
        Log.Write($"{what}：{error ?? "成功"}");
        return error is null ? 0 : 1;
    }

    static int Render(string dir, bool demo)
    {
        Directory.CreateDirectory(dir);
        void Save(Control c, string name)
        {
            Application.DoEvents();
            using var bmp = new Bitmap(Math.Max(1, c.Width), Math.Max(1, c.Height));
            c.DrawToBitmap(bmp, new Rectangle(Point.Empty, c.Size));
            bmp.Save(Path.Combine(dir, name + ".png"), ImageFormat.Png);
            Console.WriteLine($"{name}.png {c.Width}x{c.Height}");
        }
        try
        {
            List<IProduct>? demoProducts = demo ? [new DemoProduct(codex: true, "api"), new DemoProduct(codex: false, "account")] : null;
            using var app = new TrayApp(renderOnly: true, demoProducts);
            var menu = app.MenuForRender();
            menu.Show(new Point(40, 40));
            Save(menu, "menu");
            var more = menu.Items.OfType<ToolStripMenuItem>().FirstOrDefault(i => i.Text == "更多");
            if (more is not null) { more.ShowDropDown(); Save(more.DropDown, "menu-more"); }
            menu.Close();
            using (var window = app.WindowForRender()) Save(window, "window");

            var products = demoProducts ?? TrayApp.CreateProducts(_ => { });
            foreach (var p in products)
                using (var form = new ConfigureForm(p)) { form.Show(); Save(form, "configure-" + (p.IsCodex ? "codex" : "claude")); }
            var targets = products.Where(p => p.ModeWord() != "absent").Select(p => (p, p.ModeWord(), TrayView.Parse(p.Status()))).ToList();
            using (var form = new OnboardingForm(targets)) { form.Show(); Save(form, "onboarding"); }
            return 0;
        }
        catch (Exception e) { Console.Error.WriteLine(e); return 1; }
    }
}
