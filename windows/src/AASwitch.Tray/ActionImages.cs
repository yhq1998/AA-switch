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

    static Image Draw(Action<Graphics, Pen> draw)
    {
        var image = new Bitmap(16, 16);
        using var g = Graphics.FromImage(image);
        g.SmoothingMode = SmoothingMode.AntiAlias;
        using var pen = new Pen(SystemColors.MenuText, 1.3f) { StartCap = LineCap.Round, EndCap = LineCap.Round, LineJoin = LineJoin.Round };
        draw(g, pen);
        return image;
    }
}
