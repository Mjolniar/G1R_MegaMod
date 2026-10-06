// Renders the name pictures of the map pins in a blackletter face, in the look of the plain ones:
// a white plate with soft edges that follows the word, the name in dark blue (16, 23, 42), 49 pixels high.
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Drawing.Text;
using System.Text.RegularExpressions;

string npcs = args[0], outDir = args[1];
int limit = args.Length > 2 ? int.Parse(args[2]) : int.MaxValue;
Directory.CreateDirectory(outDir);
// the plain pictures say what a person offers in front of the name: (T) teaches, (M) trades, (T/M) both
var prefixes = new Dictionary<string, string> { ["teacher"] = "(T)- ", ["trader"] = "(M)- ", ["both"] = "(T/M)- " };
var entries = Regex.Matches(File.ReadAllText(npcs), "name = \"([^\"]+)\", kind = \"([a-z]+)\"[^\n]*?label = \"Assets/Labels/([^\"]+)\"")
    .Select(m => (Name: (prefixes.TryGetValue(m.Groups[2].Value, out var pre) ? pre : "") + m.Groups[1].Value, File: m.Groups[3].Value)).ToList();
Console.WriteLine($"{entries.Count} names");
const int H = 49, Pad = 15, Grow = 8;
var ink = Color.FromArgb(255, 16, 23, 42);
using var family = new FontFamily("Old English Text MT");
using var font = new Font(family, 27f, FontStyle.Regular, GraphicsUnit.Pixel);
int done = 0;
foreach (var (name, file) in entries.Take(limit))
{
    // the word on its own, to measure it and to make the plate from
    SizeF size;
    using (var probe = new Bitmap(1, 1))
    using (var g = Graphics.FromImage(probe))
    {
        g.TextRenderingHint = TextRenderingHint.AntiAliasGridFit;
        size = g.MeasureString(name, font, PointF.Empty, StringFormat.GenericTypographic);
    }
    int w = (int)Math.Ceiling(size.Width) + 2 * Pad;
    using var text = new Bitmap(w, H, PixelFormat.Format32bppArgb);
    float y = (H - font.GetHeight()) / 2f + 1f;
    using (var g = Graphics.FromImage(text))
    {
        g.Clear(Color.Transparent);
        g.TextRenderingHint = TextRenderingHint.AntiAliasGridFit;
        g.SmoothingMode = SmoothingMode.AntiAlias;
        using var brush = new SolidBrush(ink);
        g.DrawString(name, font, brush, new PointF(Pad, y), StringFormat.GenericTypographic);
    }
    // the plate: the word's shape grown by a few pixels, then softened
    var a = new float[w, H];
    for (int yy = 0; yy < H; yy++) for (int xx = 0; xx < w; xx++) a[xx, yy] = text.GetPixel(xx, yy).A / 255f;
    var grown = new float[w, H];
    for (int yy = 0; yy < H; yy++)
        for (int xx = 0; xx < w; xx++)
        {
            float m = 0;
            for (int dy = -Grow; dy <= Grow && m < 1; dy++)
                for (int dx = -Grow; dx <= Grow; dx++)
                {
                    if (dx * dx + dy * dy > Grow * Grow) continue;
                    int px = xx + dx, py = yy + dy;
                    if (px < 0 || py < 0 || px >= w || py >= H) continue;
                    if (a[px, py] > m) m = a[px, py];
                }
            grown[xx, yy] = Math.Min(1f, m * 2f);
        }
    // three box blurs of radius 2 (close to a gaussian)
    for (int pass = 0; pass < 3; pass++)
    {
        var t = new float[w, H];
        for (int yy = 0; yy < H; yy++) for (int xx = 0; xx < w; xx++)
        { float s = 0; int n = 0; for (int dx = -2; dx <= 2; dx++) { int px = xx + dx; if (px >= 0 && px < w) { s += grown[px, yy]; n++; } } t[xx, yy] = s / 5f; }
        for (int yy = 0; yy < H; yy++) for (int xx = 0; xx < w; xx++)
        { float s = 0; for (int dy = -2; dy <= 2; dy++) { int py = yy + dy; if (py >= 0 && py < H) s += t[xx, py]; } grown[xx, yy] = s / 5f; }
    }
    using var outBmp = new Bitmap(w, H, PixelFormat.Format32bppArgb);
    for (int yy = 0; yy < H; yy++)
        for (int xx = 0; xx < w; xx++)
        {
            float plate = Math.Min(1f, grown[xx, yy] * 1.15f);
            var c = text.GetPixel(xx, yy);
            float ta = c.A / 255f;
            // the word over the white plate
            float outA = ta + plate * (1 - ta);
            if (outA <= 0.002f) { outBmp.SetPixel(xx, yy, Color.FromArgb(0, 255, 255, 255)); continue; }
            float r = (ink.R * ta + 255 * plate * (1 - ta)) / outA, gg = (ink.G * ta + 255 * plate * (1 - ta)) / outA, b = (ink.B * ta + 255 * plate * (1 - ta)) / outA;
            outBmp.SetPixel(xx, yy, Color.FromArgb((int)Math.Round(outA * 255), (int)Math.Round(r), (int)Math.Round(gg), (int)Math.Round(b)));
        }
    outBmp.Save(Path.Combine(outDir, file), ImageFormat.Png);
    done++;
}
Console.WriteLine($"{done} written to {outDir}");
