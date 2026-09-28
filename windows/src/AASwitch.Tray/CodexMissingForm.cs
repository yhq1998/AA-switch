namespace AASwitch.Tray;

/// <summary>
/// 找不到 codex 命令行时的弹窗：告诉用户怎么装、找过哪些位置，并给两条出路——装完点“重新查找”（不用重启程序），
/// 或者自己指一个 codex 的位置（存进 settings.conf，不用去设环境变量）。
/// DialogResult：Retry = 重新查找，OK = 用户指了位置（在 Picked 里），Cancel = 算了。
/// </summary>
sealed class CodexMissingForm : Form
{
    public const string InstallCommand = "npm i -g @openai/codex";

    /// <summary>用户自己指的 codex 位置；只在 DialogResult.OK 时有意义。</summary>
    public string? Picked { get; private set; }

    public CodexMissingForm(IReadOnlyList<string> tried)
    {
        Text = "找不到 Codex 命令行";
        Icon = AppInfo.LoadIcon("app.ico", 32);
        Font = SystemFonts.MessageBoxFont ?? Font;
        AutoScaleDimensions = new SizeF(96, 96); AutoScaleMode = AutoScaleMode.Dpi;
        FormBorderStyle = FormBorderStyle.FixedDialog;
        MaximizeBox = MinimizeBox = false; ShowInTaskbar = true; TopMost = true;
        StartPosition = FormStartPosition.CenterScreen;
        ClientSize = new Size(520, 306);

        Controls.Add(new Label
        {
            Text = "切换 Codex 要用 codex 命令行来登录 / 登出，这台电脑上没找到它。\n装了 Codex 桌面应用的话，先打开它一次（它会把自带的命令行放好）；没装的话，在 PowerShell 里运行下面这行。然后点“重新查找”，不用重启 AA Switch：",
            Bounds = new Rectangle(16, 12, 488, 60),
        });
        Controls.Add(new TextBox   // 只读但能选中复制
        {
            Text = InstallCommand, ReadOnly = true, BackColor = SystemColors.Window,
            Bounds = new Rectangle(16, 76, 488, 24),
        });
        Controls.Add(new Label { Text = "找过下面这些位置：", ForeColor = SystemColors.GrayText, Bounds = new Rectangle(16, 108, 488, 20) });
        Controls.Add(new TextBox
        {
            Text = string.Join("\r\n", tried.Count > 0 ? tried : ["（PATH 是空的）"]),
            ReadOnly = true, Multiline = true, ScrollBars = ScrollBars.Vertical, WordWrap = false, BackColor = SystemColors.Window,
            Bounds = new Rectangle(16, 130, 488, 122),
        });

        var again = new Button { Text = "重新查找", DialogResult = DialogResult.Retry, Bounds = new Rectangle(178, 264, 90, 30) };
        var pick = new Button { Text = "选择 codex 位置…", Bounds = new Rectangle(276, 264, 130, 30) };
        var cancel = new Button { Text = "取消", DialogResult = DialogResult.Cancel, Bounds = new Rectangle(414, 264, 90, 30) };
        pick.Click += (_, _) => Pick();
        Controls.Add(again); Controls.Add(pick); Controls.Add(cancel);
        AcceptButton = again; CancelButton = cancel;
    }

    void Pick()
    {
        using var dlg = new OpenFileDialog
        {
            Title = "选择 codex 命令行",
            Filter = "codex 命令行|codex.exe;codex.cmd;codex.bat;codex|所有文件 (*.*)|*.*",
            CheckFileExists = true,
        };
        if (dlg.ShowDialog(this) != DialogResult.OK) return;
        Picked = dlg.FileName;
        DialogResult = DialogResult.OK;
        Close();
    }
}
