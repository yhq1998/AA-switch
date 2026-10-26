using System.Drawing.Drawing2D;

namespace AASwitch.Tray;

/// <summary>Shared outline icons keep product actions consistent in both More menus.</summary>
static class ActionImages
{
    public static readonly Image Configure = Draw((g, p) =>
    {
        g.DrawEllipse(p, 4, 4, 8, 8);
        g.DrawEllipse(p, 6.5f, 6.5f, 3, 3);
        for (var i = 0; i < 8; i++)
        {
            var a = i * Math.PI / 4;
            g.DrawLine(p, 8 + (float)Math.Cos(a) * 4, 8 + (float)Math.Sin(a) * 4,
                          8 + (float)Math.Cos(a) * 6, 8 + (float)Math.Sin(a) * 6);
        }
    });
    public static readonly Image Refresh = Draw((g, p) =>
    {
        g.DrawArc(p, 3, 3, 10, 10, 40, 290);
        g.DrawLines(p, [new PointF(10, 2), new PointF(13, 3.5f), new PointF(12, 7)]);
    });
    public static readonly Image Folder = Draw((g, p) =>
        g.DrawPolygon(p, [new PointF(2, 4), new PointF(6, 4), new PointF(8, 6), new PointF(14, 6), new PointF(14, 13), new PointF(2, 13)]));
    public static readonly Image Models = Draw((g, p) =>
    {
        for (var y = 4; y <= 12; y += 4) { g.DrawEllipse(p, 2, y - 1, 1, 1); g.DrawLine(p, 6, y, 14, y); }
    });
    public static readonly Image Status = Draw((g, p) =>
    {
        g.DrawArc(p, 3, 3, 10, 10, 40, 290);
        g.DrawLines(p, [new PointF(10, 2), new PointF(13, 3.5f), new PointF(12, 7)]);
    }, Color.RoyalBlue);
    public static readonly Image Update = Draw((g, p) =>
    {
        g.DrawEllipse(p, 2, 2, 12, 12);
        g.DrawLine(p, 8, 4, 8, 11);
        g.DrawLines(p, [new PointF(5, 8), new PointF(8, 11), new PointF(11, 8)]);
    }, Color.ForestGreen);
    public static readonly Image Diagnostics = Draw((g, p) =>
    {
        g.DrawRectangle(p, 3, 2, 8, 11);
        g.DrawLine(p, 5, 5, 9, 5);
        g.DrawLine(p, 5, 8, 8, 8);
        g.DrawEllipse(p, 8, 8, 5, 5);
        g.DrawLine(p, 12, 12, 15, 15);
    }, Color.MediumPurple);
    public static readonly Image Startup = Draw((g, p) =>
    {
        g.DrawArc(p, 2, 2, 12, 12, -60, 300);
        g.DrawLine(p, 8, 1, 8, 8);
    }, Color.Teal);

    static Image Draw(Action<Graphics, Pen> draw, Color? color = null)
    {
        var image = new Bitmap(16, 16);
        using var g = Graphics.FromImage(image);
        g.SmoothingMode = SmoothingMode.AntiAlias;
        using var pen = new Pen(color ?? SystemColors.MenuText, 1.3f) { StartCap = LineCap.Round, EndCap = LineCap.Round, LineJoin = LineJoin.Round };
        draw(g, pen);
        return image;
    }
}
