using System.ComponentModel;
using System.Drawing.Drawing2D;

namespace AASwitch.Tray;

/// <summary>
/// 模式行：一个分段控件，每格等宽，选中的那格用强调色高亮，点另一格就切换（点当前那格也会触发，用来“重新应用”）。
/// 自己画，是因为系统没有现成的分段控件，两个单选钮放在菜单里又不像开关。
/// </summary>
sealed class SegmentRow : Control
{
    readonly string[] _labels;
    int _hover = -1;

    [DesignerSerializationVisibility(DesignerSerializationVisibility.Hidden)]
    public int? Selected { get; set; }
    public event Action<int>? SegmentClicked;

    public SegmentRow(string[] labels, int? selected, Font font, int segmentWidth96 = 112)
    {
        _labels = labels;
        Selected = selected;
        Font = font;
        SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.UserPaint | ControlStyles.ResizeRedraw | ControlStyles.SupportsTransparentBackColor, true);
        BackColor = Color.Transparent;
        var scale = DeviceDpi / 96f;
        Size = new Size((int)(segmentWidth96 * labels.Length * scale), (int)(26 * scale));
        MinimumSize = Size;
    }

    Rectangle Cell(int i) { var w = Width / _labels.Length; return new Rectangle(i * w, 0, i == _labels.Length - 1 ? Width - i * w : w, Height); }
    int HitTest(Point p) => Enumerable.Range(0, _labels.Length).FirstOrDefault(i => Cell(i).Contains(p), -1);

    static GraphicsPath Rounded(RectangleF r, float radius)
    {
        var d = radius * 2;
        var path = new GraphicsPath();
        path.AddArc(r.X, r.Y, d, d, 180, 90); path.AddArc(r.Right - d, r.Y, d, d, 270, 90);
        path.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90); path.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
        path.CloseFigure();
        return path;
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        var g = e.Graphics;
        g.SmoothingMode = SmoothingMode.AntiAlias;
        var radius = 6f * DeviceDpi / 96f;
        var outer = new RectangleF(0.5f, 0.5f, Width - 1, Height - 1);
        using (var track = Rounded(outer, radius))
        using (var fill = new SolidBrush(Color.FromArgb(232, 232, 236)))
        using (var border = new Pen(Color.FromArgb(205, 205, 212)))
        { g.FillPath(fill, track); g.DrawPath(border, track); }

        for (var i = 0; i < _labels.Length; i++)
        {
            var cell = Cell(i);
            var on = Selected == i;
            if (on || (_hover == i && Enabled))
            {
                var inner = RectangleF.Inflate(cell, -2.5f, -2.5f);
                using var path = Rounded(inner, radius - 2);
                using var brush = new SolidBrush(on ? (Enabled ? Color.FromArgb(0, 103, 192) : Color.FromArgb(150, 170, 190)) : Color.FromArgb(214, 214, 220));
                g.FillPath(brush, path);
            }
            var color = !Enabled && !on ? SystemColors.GrayText : on ? Color.White : Color.FromArgb(30, 30, 30);
            TextRenderer.DrawText(g, _labels[i], Font, cell, color, TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.NoPrefix);
        }
    }

    protected override void OnMouseMove(MouseEventArgs e) { var h = HitTest(e.Location); if (h != _hover) { _hover = h; Invalidate(); } base.OnMouseMove(e); }
    protected override void OnMouseLeave(EventArgs e) { _hover = -1; Invalidate(); base.OnMouseLeave(e); }
    protected override void OnMouseUp(MouseEventArgs e)
    {
        base.OnMouseUp(e);
        var i = HitTest(e.Location);
        if (Enabled && e.Button == MouseButtons.Left && i >= 0) SegmentClicked?.Invoke(i);
    }
}
