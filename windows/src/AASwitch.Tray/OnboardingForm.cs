using AASwitch.Core;

namespace AASwitch.Tray;

/// <summary>首次打开的引导：把检测到的状态摆出来，让用户选每个产品从哪种模式开始（默认账号），点“应用”才真正切换。</summary>
sealed class OnboardingForm : Form
{
    readonly List<(IProduct Product, SegmentRow Choice)> _rows = [];

    /// <summary>用户选了 API 的产品为 true；只在 DialogResult.OK 时有意义。</summary>
    public List<(IProduct Product, bool WantApi)> Choices => [.. _rows.Select(r => (r.Product, r.Choice.Selected == 1))];

    public OnboardingForm(List<(IProduct Product, string Mode, List<TrayView.Line> Info)> targets)
    {
        Text = $"欢迎使用 {AppInfo.Name}";
        Icon = AppInfo.LoadIcon("app.ico", 32);
        Font = SystemFonts.MessageBoxFont ?? Font;
        AutoScaleDimensions = new SizeF(96, 96); AutoScaleMode = AutoScaleMode.Dpi;
        FormBorderStyle = FormBorderStyle.FixedDialog;
        MaximizeBox = MinimizeBox = false; TopMost = true;
        StartPosition = FormStartPosition.CenterScreen;
        const int rowHeight = 84, width = 500;
        ClientSize = new Size(width + 32, 76 + rowHeight * targets.Count + 54);

        Controls.Add(new Label
        {
            Text = "下面是检测到的当前状态。请选择每个产品从哪种模式开始，点“应用”后才会真正切换；之后随时可以在托盘菜单里切换。",
            Bounds = new Rectangle(16, 14, width, 52),
        });
        var bold = new Font(Font, FontStyle.Bold);
        var y = 76;
        foreach (var (p, mode, info) in targets)
        {
            Controls.Add(new Label { Text = p.Name, Font = bold, Bounds = new Rectangle(16, y, width, 20) });
            Controls.Add(new Label { Text = "检测到：" + TrayView.DetectedText(p, mode, info), ForeColor = SystemColors.GrayText, Bounds = new Rectangle(16, y + 22, width, 20) });
            var seg = new SegmentRow([p.AccountTitle, "API"], 0, Font) { Location = new Point(16, y + 46) };
            seg.SegmentClicked += i => { seg.Selected = i; seg.Invalidate(); };
            Controls.Add(seg);
            if (p.IsCodex)
                Controls.Add(new Label { Text = "切换前请先关掉 Codex", ForeColor = SystemColors.GrayText, Bounds = new Rectangle(16 + 236, y + 50, 250, 20) });
            _rows.Add((p, seg));
            y += rowHeight;
        }
        var apply = new Button { Text = "应用", DialogResult = DialogResult.OK, Bounds = new Rectangle(width + 16 - 196, y + 12, 90, 30) };
        var later = new Button { Text = "稍后再说", DialogResult = DialogResult.Cancel, Bounds = new Rectangle(width + 16 - 98, y + 12, 98, 30) };
        Controls.Add(apply); Controls.Add(later);
        AcceptButton = apply; CancelButton = later;
    }
}
