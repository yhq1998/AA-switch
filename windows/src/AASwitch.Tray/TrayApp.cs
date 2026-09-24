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
    Updater.Release? _latest;
    readonly System.Windows.Forms.Timer _updateTimer = new() { Interval = 6 * 60 * 60 * 1000 };   // 每 6 小时查一次
    bool _headless;          // --click 自测模式：不弹任何窗口，出错只记下来
    string? _headlessError;
    Form? _window;                  // 用户自己打开程序时弹出的窗口，内容和菜单一样
    ContextMenuStrip? _windowItems; // 窗口内容是从这份菜单项转出来的；窗口里的开关控件还挂在它下面，换内容时一起释放
    bool _windowRefreshQueued;

    public TrayApp(bool renderOnly = false, List<IProduct>? products = null, bool showWindow = false)
    {
        _ = _ui.Handle;
        _small = new Font(_menu.Font.FontFamily, _menu.Font.Size * 0.9f);
        _bold = new Font(_menu.Font, FontStyle.Bold);
        _products = products ?? CreateProducts(Say);
        _icon = new NotifyIcon { Icon = AppInfo.LoadIcon("tray.ico", SystemInformation.SmallIconSize.Width), Text = AppInfo.Name, Visible = !renderOnly, ContextMenuStrip = _menu };
        _icon.MouseUp += (_, e) => { if (e.Button == MouseButtons.Left) ShowMenuAtCursor(); };   // 左键也弹菜单
        if (renderOnly) return;
        _menu.Opening += (_, _) => { ReadModes(); Rebuild(); RefreshStatusAsync(); };
        Log.Write($"启动 {AppInfo.Name} {AppInfo.Version}（{AppInfo.ExePath}）");
        ReadModes(); Rebuild();
        RefreshStatusAsync(thenOnUi: () => { MaybeShowOnboarding(); if (showWindow) ShowWindow(); });
        Reveal.Listen(() => _ui.BeginInvoke(() => { Log.Write("另一份程序被打开，已退出，这边弹出窗口"); ShowWindow(); }));
        Autostart.Repair();
        SelfReplace.CleanUp();
        _updateTimer.Tick += async (_, _) => await CheckUpdateAsync();
        _updateTimer.Start();
        _ = CheckUpdateAsync();
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
    // 下拉菜单已经替每一项让出了左边的勾选栏，这里不用再缩进；宽度自己量，不然长文字会被菜单右边截掉
    ToolStripLabel Label(string text, Font font, Color color)
    {
        var size = TextRenderer.MeasureText(text, font, Size.Empty, TextFormatFlags.NoPrefix | TextFormatFlags.SingleLine);
        return new ToolStripLabel(text) { Font = font, ForeColor = color, AutoSize = false, Size = new Size(size.Width + 12, size.Height + 4), Margin = new Padding(0, 1, 8, 1), TextAlign = ContentAlignment.MiddleLeft };
    }

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
        BuildInto(_menu.Items, forWindow: false);
        _menu.ResumeLayout();
        // 窗口换内容放到下一轮消息循环：点的可能正是窗口里的按钮，不能在它自己的 Click 里把它释放掉
        if (_window is not null && !_windowRefreshQueued) { _windowRefreshQueued = true; _ui.BeginInvoke(RefreshWindow); }
    }

    void BuildInto(ToolStripItemCollection items, bool forWindow)
    {
        if (forWindow)
        {
            items.Add(Label($"{AppInfo.Name} 平时在任务栏右下角的托盘里（时钟旁边），点图标就能切换。看不到图标的话，点任务栏上的“^”展开；" +
                            "想让它一直显示，把图标从展开的小窗拖到任务栏上，或在“设置 → 个性化 → 任务栏 → 其他系统托盘图标”里打开 AA Switch。", _small, SystemColors.GrayText));
            items.Add(new ToolStripSeparator());
        }
        foreach (var p in _products) { AddSection(items, p); items.Add(new ToolStripSeparator()); }
        items.Add(Item("刷新状态", () => { ReadModes(); Rebuild(); RefreshStatusAsync(); }, !_busy));
        items.Add(Item("检查更新", () => _ = CheckUpdateManuallyAsync(), !_busy));
        items.Add(Item("导出诊断信息…", ExportDiagnostics, !_busy));
        var login = Item("开机自动启动", () => { Autostart.Enabled = !Autostart.Enabled; Log.Write("开机自动启动：" + Autostart.Enabled); Rebuild(); });
        login.Checked = Autostart.Enabled;
        login.Tag = CheckboxTag;
        items.Add(login);
        items.Add(new ToolStripSeparator());
        if (_busy && _busyProduct.Length == 0) items.Add(Item(_busyText, null));
        else if (UpdateAvailable) items.Add(Item($"有新版本 {_latest!.Version}，点击更新…", () => _ = ApplyUpdateAsync()));
        items.Add(Label($"{AppInfo.Name} {AppInfo.Version}", _small, SystemColors.GrayText));
        items.Add(Item("退出", () => { _icon.Visible = false; _window?.Close(); ExitThread(); }));
    }

    // ---------- 窗口：用户自己打开程序（开始菜单、双击、再次打开）时弹出。托盘图标常被收进“^”里，光靠托盘用户会以为程序没开 ----------
    const string CheckboxTag = "checkbox";

    public void ShowWindow()
    {
        if (_window is null)
        {
            _window = new Form
            {
                Text = AppInfo.Name, Icon = AppInfo.LoadIcon("app.ico", 32), Font = _menu.Font,
                FormBorderStyle = FormBorderStyle.FixedSingle, MaximizeBox = false, StartPosition = FormStartPosition.CenterScreen,
                AutoSize = true, AutoSizeMode = AutoSizeMode.GrowAndShrink, ShowInTaskbar = true, BackColor = SystemColors.Window,
            };
            _window.FormClosed += (_, _) => { _window = null; _windowItems?.Dispose(); _windowItems = null; };
            RefreshWindow();
        }
        Log.Write("显示窗口");
        _window.Show();
        if (_window.WindowState == FormWindowState.Minimized) _window.WindowState = FormWindowState.Normal;
        _window.Activate();
        SetForegroundWindow(_window.Handle);
    }

    void RefreshWindow()
    {
        _windowRefreshQueued = false;
        if (_window is null) return;
        var items = new ContextMenuStrip { Font = _menu.Font };
        BuildInto(items.Items, forWindow: true);
        var content = WindowContent(items);
        _window.SuspendLayout();
        var old = _window.Controls.Cast<Control>().ToList();
        _window.Controls.Clear();
        foreach (var c in old) c.Dispose();
        _window.Controls.Add(content);
        _window.ResumeLayout();
        _windowItems?.Dispose();
        _windowItems = items;
    }

    /// <summary>菜单项 → 窗口里的控件：文字项变标签，可点的变按钮（连着的几个排成一行），带勾的变复选框，
    /// 子菜单变“更多 ▾”按钮（点了弹出同一个子菜单），开关控件直接挪过来，分隔线照搬。</summary>
    Control WindowContent(ContextMenuStrip items)
    {
        var scale = _menu.DeviceDpi / 96f;
        var width = (int)(460 * scale);
        var panel = new FlowLayoutPanel { FlowDirection = FlowDirection.TopDown, WrapContents = false, AutoSize = true, AutoSizeMode = AutoSizeMode.GrowAndShrink, Padding = new Padding((int)(16 * scale)) };
        FlowLayoutPanel? buttonRow = null;
        foreach (ToolStripItem i in items.Items.Cast<ToolStripItem>().ToList())
        {
            var menuItem = i as ToolStripMenuItem;
            var isButton = menuItem is { DropDownItems.Count: 0, Enabled: true } && !Equals(menuItem.Tag, CheckboxTag) && menuItem.Font != _small;
            if (!isButton) buttonRow = null;
            switch (i)
            {
                case ToolStripSeparator:
                    panel.Controls.Add(new Label { AutoSize = false, Width = width, Height = 1, BackColor = SystemColors.ControlLight, Margin = new Padding(0, (int)(8 * scale), 0, (int)(8 * scale)) });
                    break;
                case ToolStripControlHost host:
                    var control = host.Control;
                    control.Margin = new Padding(0, (int)(4 * scale), 0, (int)(4 * scale));
                    panel.Controls.Add(control);   // 从菜单项上挪过来；原来的菜单项跟着 _windowItems 一起释放
                    break;
                case ToolStripLabel label:
                    panel.Controls.Add(new Label { Text = label.Text, Font = label.Font, ForeColor = label.ForeColor, AutoSize = true, MaximumSize = new Size(width, 0), UseMnemonic = false, Margin = new Padding(0, 2, 0, 2) });
                    break;
                case ToolStripMenuItem { DropDownItems.Count: > 0 } more:
                    var drop = new Button { Text = more.Text + " ▾", AutoSize = true, FlatStyle = FlatStyle.System };
                    drop.Click += (_, _) => more.DropDown.Show(drop, new Point(0, drop.Height));
                    panel.Controls.Add(drop);
                    break;
                case ToolStripMenuItem box when Equals(box.Tag, CheckboxTag):
                    var check = new CheckBox { Text = box.Text, Checked = box.Checked, AutoSize = true, Margin = new Padding(0, (int)(4 * scale), 0, 0) };
                    check.CheckedChanged += (_, _) => box.PerformClick();
                    panel.Controls.Add(check);
                    break;
                case ToolStripMenuItem link when link.Enabled && link.Font == _small:   // 可点的小字说明（比如“还没配置 API 地址，点击填写…”）
                    var linkLabel = new LinkLabel { Text = link.Text, Font = link.Font, AutoSize = true, MaximumSize = new Size(width, 0), Margin = new Padding(0, 2, 0, 2) };
                    linkLabel.LinkClicked += (_, _) => link.PerformClick();
                    panel.Controls.Add(linkLabel);
                    break;
                case ToolStripMenuItem action when isButton:
                    if (buttonRow is null)
                    {
                        buttonRow = new FlowLayoutPanel { AutoSize = true, WrapContents = true, MaximumSize = new Size(width, 0), Margin = new Padding(0, 2, 0, 2) };
                        panel.Controls.Add(buttonRow);
                    }
                    var button = new Button { Text = action.Text, AutoSize = true, FlatStyle = FlatStyle.System, Margin = new Padding(0, 0, (int)(8 * scale), 0) };
                    button.Click += (_, _) => action.PerformClick();
                    buttonRow.Controls.Add(button);
                    break;
                case ToolStripMenuItem text:   // 不可点的：正在切换…、详细信息
                    panel.Controls.Add(new Label { Text = text.Text, AutoSize = true, MaximumSize = new Size(width, 0), ForeColor = SystemColors.GrayText, UseMnemonic = false, Margin = new Padding(0, 2, 0, 2) });
                    break;
            }
        }
        return panel;
    }

    void AddSection(ToolStripItemCollection items, IProduct p)
    {
        var mode = _mode.GetValueOrDefault(p.Name, "unknown");
        var view = TrayView.Build(p, mode, _status.GetValueOrDefault(p.Name), AppInfo.Name);
        items.Add(Label(p.Name, _bold, SystemColors.ControlText));
        if (view.Unavailable is not null) { items.Add(Small(view.Unavailable)); return; }

        if (_busy && _busyProduct == p.Name) items.Add(Item(_busyText, null));
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
            items.Add(new ToolStripControlHost(row) { AutoSize = false, Size = row.Size, Margin = new Padding(2, 3, 12, 3) });
        }
        items.Add(Small(view.UrlLine, view.UrlLineOpensConfigure ? () => OpenConfigure(p) : null));
        foreach (var note in view.Notes) items.Add(Small(note));
        foreach (var w in view.Warnings) items.Add(Label(w, _menu.Font, Color.FromArgb(170, 90, 0)));

        var more = new ToolStripMenuItem("更多");
        more.DropDownItems.Add(Item("配置 API 地址 / key…", () => OpenConfigure(p), !_busy));
        if (view.CanReapply && !_busy) more.DropDownItems.Add(Item("重新应用 API 配置", () => EnsureConfiguredThenSwitch(p)));
        more.DropDownItems.Add(Item("打开备份文件夹", () => { Directory.CreateDirectory(p.BackupsDir); Process.Start("explorer.exe", $"\"{p.BackupsDir}\""); }));
        if (view.Details.Count > 0 || !_status.ContainsKey(p.Name)) more.DropDownItems.Add(new ToolStripSeparator());
        if (!_status.ContainsKey(p.Name)) more.DropDownItems.Add(Item("正在读取状态…", null));
        foreach (var d in view.Details) more.DropDownItems.Add(Item(d, null));
        items.Add(more);
    }

    // ---------- 切换 ----------
    /// <summary>切到 API 之前先确认地址和 key 都齐了：没有就弹配置表单，保存后接着切；用户取消就什么都不做。</summary>
    void EnsureConfiguredThenSwitch(IProduct p, Action? then = null)
    {
        var url = p.LoadConfig().Url;
        if (url.Length > 0 && p.FindKey(url).Length > 0) { _ = DoSwitchAsync(p, toApi: true, then); return; }
        Log.Write($"{p.Name} 切到 API 前还没配好（地址：{(url.Length == 0 ? "无" : url)}），先弹配置表单");
        if (_headless) { _headlessError = "还没配置地址或 key"; then?.Invoke(); return; }
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
            if (!_headless) _icon.ShowBalloonTip(4000, p.Name, last, ToolTipIcon.Info);
            then?.Invoke();
            return;
        }
        Log.Write($"{p.Name} {what}失败：{error}");
        if (_headless) { _headlessError = error.Message; then?.Invoke(); return; }
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

    // ---------- 检查更新：读官网的 latest.json；新版本下载、校验后换掉自己再重新打开，任何一步不对就不动现有安装 ----------
    bool UpdateAvailable => _latest is not null && Updater.IsNewer(_latest.Version, AppInfo.Version);

    /// <summary>返回失败原因，null 表示查到了（不一定有新版）。</summary>
    async Task<string?> CheckUpdateAsync()
    {
        if (AppInfo.UpdateUrl.Length == 0) return "这个版本没有配置更新地址。";
        try
        {
            _latest = await Task.Run(() => Updater.CheckAsync(AppInfo.UpdateUrl));
            if (UpdateAvailable) { Log.Write($"发现新版本 {_latest!.Version}（当前 {AppInfo.Version}）"); Rebuild(); }
            return null;
        }
        catch (SwitchException e) { Log.Write("检查更新失败：" + e.Message); return e.Message; }
    }

    async Task CheckUpdateManuallyAsync()
    {
        if (_busy) return;
        Log.Write("用户点击：检查更新");
        var failure = await CheckUpdateAsync();
        if (failure is not null) MessageBox.Show(failure, "检查更新失败", MessageBoxButtons.OK, MessageBoxIcon.Warning);
        else if (!UpdateAvailable) MessageBox.Show($"{AppInfo.Name} {AppInfo.Version}", "已是最新版本", MessageBoxButtons.OK, MessageBoxIcon.Information);
        else if (MessageBox.Show($"当前是 {AppInfo.Version}。更新会自动下载、校验并替换程序，然后重新打开，几十秒完成。\n\n现在更新吗？", $"发现新版本 {_latest!.Version}", MessageBoxButtons.YesNo, MessageBoxIcon.Information) == DialogResult.Yes)
            await ApplyUpdateAsync();
    }

    /// <summary>下载、校验、替换。成功后（非自测模式）重新打开新版本并退出；返回失败原因，成功为 null。</summary>
    public async Task<string?> ApplyUpdateAsync()
    {
        if (_busy || _latest is null) return "没有可用的更新";
        var release = _latest;
        Log.Write($"更新到 {release.Version}");
        _busy = true; _busyProduct = ""; _busyText = $"正在下载 {AppInfo.Name} {release.Version}…";
        UpdateTooltip(); Rebuild();
        string? failure = null;
        try
        {
            var tmp = Path.Combine(AppInfo.DataDir, "update", $"{AppInfo.Name} {release.Version}.exe");
            await Task.Run(() => Updater.DownloadAsync(release, AppInfo.UpdateUrl, tmp));
            SelfReplace.Swap(tmp);
        }
        catch (SwitchException e) { failure = e.Message; }
        _busy = false;
        UpdateTooltip(); Rebuild();
        if (failure is not null)
        {
            Log.Write("更新失败：" + failure);
            if (!_headless) MessageBox.Show(failure + "\n\n现有安装没有改动。", "更新失败", MessageBoxButtons.OK, MessageBoxIcon.Warning);
            return failure;
        }
        Log.Write("更新包校验通过，已替换程序" + (_headless ? "" : "，重新打开"));
        if (_headless) return null;
        Process.Start(new ProcessStartInfo(AppInfo.ExePath, "--after-update") { UseShellExecute = false });
        _icon.Visible = false;
        ExitThread();
        return null;
    }

    /// <summary>给 CI 自测用：查一次更新，有新版就替换自己（不重新打开）。返回失败原因，成功为 null。</summary>
    public async Task<string?> UpdateForTestAsync()
    {
        _headless = true;
        var failure = await CheckUpdateAsync();
        if (failure is not null) return failure;
        return UpdateAvailable ? await ApplyUpdateAsync() : "没有比当前更新的版本";
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
        if (disposing) { _window?.Dispose(); _windowItems?.Dispose(); _updateTimer.Dispose(); _icon.Dispose(); _menu.Dispose(); _ui.Dispose(); _small.Dispose(); _bold.Dispose(); }
        base.Dispose(disposing);
    }

    /// <summary>给 CI 自测用：不弹窗口，走一遍“点了分段控件的某一格”之后的同一条路径；返回错误信息，成功为 null。</summary>
    public Task<string?> ClickForTestAsync(string productName, bool toApi)
    {
        _headless = true;
        var done = new TaskCompletionSource<string?>();
        var p = _products.First(x => (x.IsCodex ? "codex" : "claude") == productName);
        ReadModes();
        if (toApi) EnsureConfiguredThenSwitch(p, () => done.TrySetResult(_headlessError));
        else _ = DoSwitchAsync(p, toApi: false, () => done.TrySetResult(_headlessError));
        return done.Task;
    }

    /// <summary>给 CI 截图用：让菜单带着当前状态同步读一遍，返回菜单控件。</summary>
    public Form WindowForRender()
    {
        ShowWindow();
        return _window!;
    }

    public ContextMenuStrip MenuForRender()
    {
        ReadModes();
        foreach (var p in _products) if (_mode[p.Name] != "absent") _status[p.Name] = p.Status();
        Rebuild();
        return _menu;
    }
}
