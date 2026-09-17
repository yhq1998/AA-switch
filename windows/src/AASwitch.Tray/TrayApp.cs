using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using AASwitch.Core;

namespace AASwitch.Tray;

/// <summary>
/// 托盘图标和菜单。每个产品一组：标题、一行“账号 | API”分段控件、小字的 API 地址、只在异常时出现的提示行；
/// 配置、重新应用和详细信息收进“更多”子菜单。菜单该显示什么由 Core 的 TrayView 决定，这里只负责画和响应点击。
/// </summary>
sealed class TrayApp : ApplicationContext
{
    readonly NotifyIcon _icon;
    readonly ContextMenuStrip _menu = new() { ShowImageMargin = false, ShowCheckMargin = true };
    readonly Control _ui = new();   // 用来把后台线程的结果送回界面线程
    readonly List<IProduct> _products;
    readonly List<string> _said = [];   // Core 在一次操作里说的话，成功后挑最后一句做气泡提示
    readonly Dictionary<string, string> _mode = [];
    readonly Dictionary<string, List<string>> _status = [];
    readonly Font _small, _bold;
    bool _busy;
    string _busyProduct = "", _busyText = "";
    bool _onboardingShown;

    public TrayApp(bool renderOnly = false)
    {
        _ = _ui.Handle;
        _small = new Font(_menu.Font.FontFamily, _menu.Font.Size * 0.9f);
        _bold = new Font(_menu.Font, FontStyle.Bold);
        _products = CreateProducts(Say);
        _icon = new NotifyIcon { Icon = AppInfo.LoadIcon("tray.ico", SystemInformation.SmallIconSize.Width), Text = AppInfo.Name, Visible = !renderOnly, ContextMenuStrip = _menu };
        _icon.MouseUp += (_, e) => { if (e.Button == MouseButtons.Left) ShowMenuAtCursor(); };   // 左键也弹菜单
        if (renderOnly) return;
        _menu.Opening += (_, _) => { ReadModes(); Rebuild(); RefreshStatusAsync(); };
        Log.Write($"启动 {AppInfo.Name} {AppInfo.Version}（{AppInfo.ExePath}）");
        ReadModes(); Rebuild();
        RefreshStatusAsync(thenOnUi: MaybeShowOnboarding);
    }

    public static List<IProduct> CreateProducts(Action<string> say)
    {
        var paths = AppPaths.FromEnvironment();
        var secrets = new WindowsCredentialStore();
        var codexBin = CodexCli.Find();
        var codex = new CodexMode(paths, secrets, codexBin is null ? null : new CodexCli(codexBin, paths.CodexHome), say, CodexProcesses.Running);
        return [new CodexProduct(codex, paths, secrets, codexBin is not null), new ClaudeProduct(new ClaudeMode(paths, secrets, say), paths, secrets)];
    }

    void Say(string s) { Log.Write("  " + s); lock (_said) _said.Add(s); }

    // ---------- 状态 ----------
    void ReadModes()
    {
        foreach (var p in _products)
            try { _mode[p.Name] = p.ModeWord(); } catch (Exception e) { _mode[p.Name] = "unknown"; Log.Write($"读取 {p.Name} 模式失败：{e.Message}"); }
        UpdateTooltip();
    }

    void RefreshStatusAsync(Action? thenOnUi = null) => Task.Run(() =>
    {
        var fresh = new Dictionary<string, List<string>>();
        foreach (var p in _products)
            try { if (p.ModeWord() != "absent") fresh[p.Name] = p.Status(); }
            catch (Exception e) { fresh[p.Name] = ["注意：读取状态失败，" + e.Message]; Log.Write($"读取 {p.Name} 状态失败：{e}"); }
        _ui.BeginInvoke(() =>
        {
            var changed = _products.Any(p => !(fresh.GetValueOrDefault(p.Name) ?? []).SequenceEqual(_status.GetValueOrDefault(p.Name) ?? ["?"]));
            foreach (var (k, v) in fresh) _status[k] = v;
            if (changed) { ReadModes(); Rebuild(); }
            thenOnUi?.Invoke();
        });
    });

    void UpdateTooltip()
    {
        var text = _busy ? _busyText : TrayView.Tooltip(_products.Select(p => (p, _mode.GetValueOrDefault(p.Name, "unknown"))));
        _icon.Text = text.Length > 127 ? text[..127] : text;   // NotifyIcon.Text 的上限
    }

    // ---------- 菜单 ----------
    [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr hWnd);

    void ShowMenuAtCursor()
    {
        SetForegroundWindow(_ui.Handle);   // 不先拿到前台，点菜单外面时菜单不会自己关
        _menu.Show(Cursor.Position);
    }

    ToolStripMenuItem Item(string text, Action? onClick = null, bool enabled = true)
    {
        var item = new ToolStripMenuItem(text) { Enabled = enabled && onClick is not null };
        if (onClick is not null) item.Click += (_, _) => onClick();
        return item;
    }

    // 标题、小字说明、警告用 ToolStripLabel：禁用的菜单项一律画成灰色，不认 ForeColor 和字体颜色
    static readonly Padding LabelMargin = new(30, 1, 8, 1);   // 左边让出勾选栏的宽度，和菜单项的文字对齐
    ToolStripLabel Label(string text, Font font, Color color) => new(text) { Font = font, ForeColor = color, Margin = LabelMargin, TextAlign = ContentAlignment.MiddleLeft };

    ToolStripItem Small(string text, Action? onClick = null)
    {
        if (onClick is null) return Label(text, _small, SystemColors.GrayText);
        var item = new ToolStripMenuItem(text) { Font = _small, ForeColor = Color.FromArgb(0, 103, 192) };
        item.Click += (_, _) => onClick();
        return item;
    }

    public void Rebuild()
    {
        _menu.SuspendLayout();
        _menu.Items.Clear();
        foreach (var p in _products) { AddSection(p); _menu.Items.Add(new ToolStripSeparator()); }
        _menu.Items.Add(Item("刷新状态", () => { ReadModes(); Rebuild(); RefreshStatusAsync(); }, !_busy));
        _menu.Items.Add(Item("导出诊断信息…", ExportDiagnostics, !_busy));
        var login = Item("开机自动启动", () => { Autostart.Enabled = !Autostart.Enabled; Log.Write("开机自动启动：" + Autostart.Enabled); });
        login.Checked = Autostart.Enabled;
        _menu.Items.Add(login);
        _menu.Items.Add(new ToolStripSeparator());
        _menu.Items.Add(Label($"{AppInfo.Name} {AppInfo.Version}", _small, SystemColors.GrayText));
        _menu.Items.Add(Item("退出", () => { _icon.Visible = false; ExitThread(); }));
        _menu.ResumeLayout();
    }

    void AddSection(IProduct p)
    {
        var mode = _mode.GetValueOrDefault(p.Name, "unknown");
        var view = TrayView.Build(p, mode, _status.GetValueOrDefault(p.Name), AppInfo.Name);
        _menu.Items.Add(Label(p.Name, _bold, SystemColors.ControlText));
        if (view.Unavailable is not null) { _menu.Items.Add(Small(view.Unavailable)); return; }

        if (_busy && _busyProduct == p.Name) _menu.Items.Add(Item(_busyText, null));
        else
        {
            var row = new SegmentRow([p.AccountTitle, "API"], view.Selected, _menu.Font) { Enabled = !_busy };
            row.SegmentClicked += i =>
            {
                _menu.Close();
                var info = TrayView.Parse(_status.GetValueOrDefault(p.Name) ?? []);
                var wantApi = i == 1;
                // 点的就是当前模式：只有状态不一致（Codex 配置和登录方式对不上）时才重新切一次，否则什么都不做
                if (!TrayView.NeedsSwitch(p, mode, info, wantApi) && !(mode == "none" && !wantApi)) return;
                if (wantApi) EnsureConfiguredThenSwitch(p); else _ = DoSwitchAsync(p, toApi: false);
            };
            _menu.Items.Add(new ToolStripControlHost(row) { AutoSize = false, Size = row.Size, Margin = new Padding(28, 2, 12, 2) });
        }
        _menu.Items.Add(Small(view.UrlLine, view.UrlLineOpensConfigure ? () => OpenConfigure(p) : null));
        foreach (var note in view.Notes) _menu.Items.Add(Small(note));
        foreach (var w in view.Warnings) _menu.Items.Add(Label(w, _menu.Font, Color.FromArgb(170, 90, 0)));

        var more = new ToolStripMenuItem("更多");
        more.DropDownItems.Add(Item("配置 API 地址 / key…", () => OpenConfigure(p), !_busy));
        if (view.CanReapply && !_busy) more.DropDownItems.Add(Item("重新应用 API 配置", () => EnsureConfiguredThenSwitch(p)));
        more.DropDownItems.Add(Item("打开备份文件夹", () => { Directory.CreateDirectory(p.BackupsDir); Process.Start("explorer.exe", $"\"{p.BackupsDir}\""); }));
        more.DropDownItems.Add(new ToolStripSeparator());
        if (!_status.ContainsKey(p.Name)) more.DropDownItems.Add(Item("正在读取状态…", null));
        foreach (var d in view.Details) more.DropDownItems.Add(Item(d, null));
        _menu.Items.Add(more);
    }

    // ---------- 切换 ----------
    /// <summary>切到 API 之前先确认地址和 key 都齐了：没有就弹配置表单，保存后接着切；用户取消就什么都不做。</summary>
    void EnsureConfiguredThenSwitch(IProduct p, Action? then = null)
    {
        var url = p.LoadConfig().Url;
        if (url.Length > 0 && p.FindKey(url).Length > 0) { _ = DoSwitchAsync(p, toApi: true, then); return; }
        Log.Write($"{p.Name} 切到 API 前还没配好（地址：{(url.Length == 0 ? "无" : url)}），先弹配置表单");
        using var form = new ConfigureForm(p);
        if (form.ShowDialog() == DialogResult.OK) _ = DoSwitchAsync(p, toApi: true, then); else then?.Invoke();
    }

    async Task DoSwitchAsync(IProduct p, bool toApi, Action? then = null)
    {
        if (_busy) { then?.Invoke(); return; }
        var what = toApi ? "切到 API" : $"切回{p.AccountTitle}";
        Log.Write($"用户点击：{p.Name} {what}");
        lock (_said) _said.Clear();
        _busy = true; _busyProduct = p.Name; _busyText = $"正在切换 {p.Name}…";
        UpdateTooltip(); Rebuild();
        Exception? error = null;
        try { await Task.Run(async () => { if (toApi) await p.SwitchToApiAsync(); else p.SwitchToAccount(); }); }
        catch (Exception e) { error = e; }
        _busy = false; _busyProduct = "";
        ReadModes(); Rebuild(); RefreshStatusAsync();
        if (error is null)
        {
            string last; lock (_said) last = _said.LastOrDefault(s => s.StartsWith("已切")) ?? $"{what}完成。";
            _icon.ShowBalloonTip(4000, p.Name, last, ToolTipIcon.Info);
            then?.Invoke();
            return;
        }
        Log.Write($"{p.Name} {what}失败：{error}");
        var text = error is SwitchException ? error.Message : $"{error.GetType().Name}：{error.Message}\n\n请点托盘菜单里的“导出诊断信息”，把桌面上生成的文件发给管理员。";
        MessageBox.Show(text, $"{p.Name} {what}失败", MessageBoxButtons.OK, MessageBoxIcon.Warning);
    }

    /// <summary>配置表单；保存后如果当前就在 API 模式，立即重新切换让新地址 / 新 key 生效。</summary>
    void OpenConfigure(IProduct p)
    {
        using var form = new ConfigureForm(p);
        if (form.ShowDialog() != DialogResult.OK) return;
        if (_mode.GetValueOrDefault(p.Name) == "api") { _ = DoSwitchAsync(p, toApi: true); return; }
        RefreshStatusAsync();
        MessageBox.Show($"{p.Name} 当前是{p.AccountTitle}模式，新地址会在下次切换到 API 时使用。", "已保存", MessageBoxButtons.OK, MessageBoxIcon.Information);
    }

    // ---------- 初始设置 ----------
    void MaybeShowOnboarding()
    {
        if (_onboardingShown || _busy || Settings.OnboardingDone) return;
        var targets = _products
            .Select(p => (Product: p, Mode: _mode.GetValueOrDefault(p.Name, "unknown"), Info: TrayView.Parse(_status.GetValueOrDefault(p.Name) ?? [])))
            .Where(t => t.Mode is not ("absent" or "unknown") && _status.ContainsKey(t.Product.Name)).ToList();
        if (targets.Count == 0) return;
        _onboardingShown = true;
        Log.Write("首次打开，显示初始设置");
        using var form = new OnboardingForm(targets);
        var result = form.ShowDialog();
        Settings.OnboardingDone = true;
        if (result != DialogResult.OK) { Log.Write("初始设置：稍后再说"); return; }
        var plan = form.Choices.Where(c => { var t = targets.First(x => x.Product == c.Product); return TrayView.NeedsSwitch(c.Product, t.Mode, t.Info, c.WantApi); }).ToList();
        Log.Write("初始设置：" + (plan.Count == 0 ? "无需改动" : string.Join("；", plan.Select(c => $"{c.Product.Name} {(c.WantApi ? "api" : c.Product.AccountWord)}"))));
        RunPlan(plan);
    }

    /// <summary>依次对多个产品执行切换，前一个做完再做下一个。</summary>
    void RunPlan(List<(IProduct Product, bool WantApi)> plan)
    {
        if (plan.Count == 0) return;
        var (p, wantApi) = plan[0];
        var rest = plan[1..];
        if (wantApi) EnsureConfiguredThenSwitch(p, () => RunPlan(rest)); else _ = DoSwitchAsync(p, toApi: false, () => RunPlan(rest));
    }

    // ---------- 导出诊断信息：版本、系统、两个产品的状态和最近的日志，写成一个文本文件放到桌面 ----------
    void ExportDiagnostics()
    {
        Log.Write("用户点击：导出诊断信息");
        var r = new StringBuilder();
        r.AppendLine($"{AppInfo.Name} 诊断信息  {DateTime.Now:O}").AppendLine();
        r.AppendLine("== 应用").AppendLine($"版本：{AppInfo.Version}").AppendLine($"位置：{AppInfo.ExePath}").AppendLine();
        r.AppendLine("== 系统").AppendLine($"Windows：{Environment.OSVersion.VersionString}，{RuntimeInformation.OSArchitecture}（进程 {RuntimeInformation.ProcessArchitecture}）");
        r.AppendLine($".NET：{RuntimeInformation.FrameworkDescription}").AppendLine($"用户：{Environment.UserName}，HOME：{Environment.GetFolderPath(Environment.SpecialFolder.UserProfile)}");
        r.AppendLine($"PATH：{Environment.GetEnvironmentVariable("PATH")}").AppendLine();
        foreach (var p in _products)
        {
            r.AppendLine($"== {p.Name}").AppendLine($"数据目录：{p.DataDir}");
            try { r.AppendLine($"模式：{p.ModeWord()}"); foreach (var l in p.ModeWord() == "absent" ? [] : p.Status()) r.AppendLine("  " + l); }
            catch (Exception e) { r.AppendLine("  读取失败：" + e); }
            r.AppendLine();
        }
        r.AppendLine("== 相关程序").AppendLine($"codex：{CodexCli.Find() ?? "（PATH 里没有）"}").AppendLine($"正在运行的 Codex 进程：{string.Join("、", CodexProcesses.Running())}").AppendLine();
        r.AppendLine($"== 最近的日志（{Log.FilePath}）").AppendLine(Log.Tail(300));
        var file = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory), $"{AppInfo.Name} 诊断 {DateTime.Now:yyyyMMdd-HHmmss}.txt");
        try { File.WriteAllText(file, r.ToString(), new UTF8Encoding(true)); Process.Start("explorer.exe", $"/select,\"{file}\""); }
        catch (Exception e) { MessageBox.Show(e.Message, "导出失败", MessageBoxButtons.OK, MessageBoxIcon.Warning); }
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing) { _icon.Dispose(); _menu.Dispose(); _ui.Dispose(); _small.Dispose(); _bold.Dispose(); }
        base.Dispose(disposing);
    }

    /// <summary>给 CI 截图用：让菜单带着当前状态同步读一遍，返回菜单控件。</summary>
    public ContextMenuStrip MenuForRender()
    {
        ReadModes();
        foreach (var p in _products) if (_mode[p.Name] != "absent") _status[p.Name] = p.Status();
        Rebuild();
        return _menu;
    }
}
