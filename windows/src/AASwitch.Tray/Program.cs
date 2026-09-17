using System.Drawing.Imaging;
using AASwitch.Core;
using AASwitch.Tray;

// AA Switch 托盘程序。不带参数：常驻托盘（只允许一个实例）。
//   --click <codex|claude> <api|account>   不显示界面，走一遍点击分段控件后的切换流程然后退出（退出码 0 表示成功）。给 CI 用。
//   --render <目录>   把菜单、配置表单和初始设置画成 PNG 存到目录里然后退出。给 CI 用：没有人盯着 Windows 屏幕时也能看到界面长什么样。
static class Program
{
    [STAThread]
    static int Main(string[] args)
    {
        ApplicationConfiguration.Initialize();
        if (args.Length == 2 && args[0] == "--render") return Render(args[1]);
        if (args.Length == 3 && args[0] == "--click") return Click(args[1], args[2] == "api");

        using var single = new Mutex(true, @"Local\AASwitch.Tray", out var first);
        if (!first) return 0;
        Application.ThreadException += (_, e) => { Log.Write("未处理的异常：" + e.Exception); MessageBox.Show(e.Exception.Message, AppInfo.Name, MessageBoxButtons.OK, MessageBoxIcon.Warning); };
        Application.Run(new TrayApp());
        return 0;
    }

    static int Click(string product, bool toApi)
    {
        using var app = new TrayApp(renderOnly: true);
        string? error = "没有完成";
        app.ClickForTestAsync(product, toApi).ContinueWith(t => { error = t.Result; Application.ExitThread(); }, TaskScheduler.FromCurrentSynchronizationContext());
        Application.Run();
        Log.Write($"--click {product} {(toApi ? "api" : "account")}：{error ?? "成功"}");
        return error is null ? 0 : 1;
    }

    static int Render(string dir)
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
            using var app = new TrayApp(renderOnly: true);
            var menu = app.MenuForRender();
            menu.Show(new Point(40, 40));
            Save(menu, "menu");
            var more = menu.Items.OfType<ToolStripMenuItem>().FirstOrDefault(i => i.Text == "更多");
            if (more is not null) { more.ShowDropDown(); Save(more.DropDown, "menu-more"); }
            menu.Close();

            var products = TrayApp.CreateProducts(_ => { });
            foreach (var p in products)
                using (var form = new ConfigureForm(p)) { form.Show(); Save(form, "configure-" + (p.IsCodex ? "codex" : "claude")); }
            var targets = products.Where(p => p.ModeWord() != "absent").Select(p => (p, p.ModeWord(), TrayView.Parse(p.Status()))).ToList();
            using (var form = new OnboardingForm(targets)) { form.Show(); Save(form, "onboarding"); }
            return 0;
        }
        catch (Exception e) { Console.Error.WriteLine(e); return 1; }
    }
}
