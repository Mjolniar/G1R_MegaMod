using System.ComponentModel;
using System.Drawing.Drawing2D;
using System.Runtime.InteropServices;

namespace G1RRepopulateSettings;

// Windows XP "Luna Blue" look, drawn by hand (modern Windows has no Luna theme).

internal static class Xp
{
    public static Color C(int rgb) => Color.FromArgb((rgb >> 16) & 255, (rgb >> 8) & 255, rgb & 255);

    public static readonly Color Face = C(0xECE9D8);
    public static readonly Color Page = C(0xFCFCFE);
    public static readonly Color TabBorder = C(0x919B9C);
    public static readonly Color FieldBorder = C(0x7F9DB9);
    public static readonly Color ButtonBorder = C(0x003C74);
    public static readonly Color DisabledBorder = C(0xC9C7BA);
    public static readonly Color DisabledText = C(0xACA899);
    public static readonly Color GroupBorder = C(0xD0D0BF);
    public static readonly Color GroupText = C(0x0046D5);
    public static readonly Color Selection = C(0x316AC5);
    public static readonly Color CheckBorder = C(0x1C5180);
    public static readonly Color CheckGreen = C(0x21A121);
    public static readonly Color TooltipBack = C(0xFFFFE1);
    public static readonly Color Hint = C(0x4D4D4D);
    public static readonly Color GridLine = C(0xE2DECD);
    public static readonly Color ArrowGlyph = C(0x4D6185);

    public static readonly Font UiFont = new("Tahoma", 8.25f);
    public static readonly Font UiBold = new("Tahoma", 8.25f, FontStyle.Bold);
    public static readonly Font TitleFont = new("Trebuchet MS", 10f, FontStyle.Bold);

    public static float Scale(Control c) => c.DeviceDpi / 96f;

    public static GraphicsPath Round(RectangleF r, float radius)
    {
        var p = new GraphicsPath();
        float d = Math.Max(1f, radius * 2);
        if (radius <= 0.5f) { p.AddRectangle(r); return p; }
        p.AddArc(r.X, r.Y, d, d, 180, 90);
        p.AddArc(r.Right - d, r.Y, d, d, 270, 90);
        p.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
        p.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
        p.CloseFigure();
        return p;
    }

    public static GraphicsPath RoundTop(RectangleF r, float radius)
    {
        var p = new GraphicsPath();
        float d = Math.Max(1f, radius * 2);
        p.AddArc(r.X, r.Y, d, d, 180, 90);
        p.AddArc(r.Right - d, r.Y, d, d, 270, 90);
        p.AddLine(r.Right, r.Y + radius, r.Right, r.Bottom);
        p.AddLine(r.Right, r.Bottom, r.X, r.Bottom);
        p.CloseFigure();
        return p;
    }

    public static void VGradient(Graphics g, Rectangle r, Color top, Color bottom)
    {
        if (r.Width <= 0 || r.Height <= 0) return;
        using var b = new LinearGradientBrush(new Rectangle(r.X, r.Y - 1, r.Width, r.Height + 2), top, bottom, LinearGradientMode.Vertical);
        g.FillRectangle(b, r);
    }

    /// <summary>XP check box: 13x13 box, blue border, light gradient, green tick.</summary>
    public static void DrawCheckBox(Graphics g, Rectangle box, bool isChecked, bool hot, bool pressed, bool enabled)
    {
        var old = g.SmoothingMode;
        g.SmoothingMode = SmoothingMode.None;
        Color border = enabled ? CheckBorder : DisabledBorder;
        Rectangle inner = new(box.X + 1, box.Y + 1, box.Width - 2, box.Height - 2);
        if (!enabled) { using var bb = new SolidBrush(Color.White); g.FillRectangle(bb, inner); }
        else if (pressed) VGradient(g, inner, C(0xB0B0A7), C(0xE3E1D4));
        else
        {
            using var lb = new LinearGradientBrush(new Rectangle(inner.X - 1, inner.Y - 1, inner.Width + 2, inner.Height + 2), C(0xDCDCD7), Color.White, 45f);
            g.FillRectangle(lb, inner);
        }
        if (hot && enabled && !pressed)
        {
            using var hp1 = new Pen(C(0xFFF0CF));
            using var hp2 = new Pen(C(0xF8B330));
            g.DrawRectangle(hp2, inner.X, inner.Y, inner.Width - 1, inner.Height - 1);
            g.DrawRectangle(hp1, inner.X + 1, inner.Y + 1, inner.Width - 3, inner.Height - 3);
        }
        using (var bp = new Pen(border)) g.DrawRectangle(bp, box.X, box.Y, box.Width - 1, box.Height - 1);
        if (isChecked)
        {
            g.SmoothingMode = SmoothingMode.AntiAlias;
            float s = box.Width / 13f;
            var pts = new[]
            {
                new PointF(box.X + 3.2f * s, box.Y + 6.0f * s),
                new PointF(box.X + 5.4f * s, box.Y + 8.4f * s),
                new PointF(box.X + 9.8f * s, box.Y + 3.6f * s),
            };
            using var cp = new Pen(enabled ? CheckGreen : DisabledText, Math.Max(2f, 2.2f * s)) { LineJoin = LineJoin.Round, StartCap = LineCap.Round, EndCap = LineCap.Round };
            g.DrawLines(cp, pts);
        }
        g.SmoothingMode = old;
    }

    public enum Arrow { Up, Down }

    /// <summary>XP scroll / spin / combo button: light blue rounded face with a dark blue arrow.</summary>
    public static void DrawArrowButton(Graphics g, Rectangle r, Arrow dir, bool hot, bool pressed, bool enabled, float scale)
    {
        if (r.Width < 3 || r.Height < 3) return;
        var old = g.SmoothingMode;
        g.SmoothingMode = SmoothingMode.AntiAlias;
        Color top, bottom, border;
        if (!enabled) { top = C(0xF7F7F7); bottom = C(0xE8E8E3); border = C(0xE8E8DF); }
        else if (pressed) { top = C(0x6E8EF1); bottom = C(0xA1BBF7); border = C(0x7D9CEF); }
        else if (hot) { top = C(0xFDFFFF); bottom = C(0xB9DAFB); border = C(0x98B1E9); }
        else { top = C(0xE3EBFD); bottom = C(0xB4C9F8); border = C(0xA4B9EC); }
        var rf = new RectangleF(r.X + 0.5f, r.Y + 0.5f, r.Width - 1.5f, r.Height - 1.5f);
        using (var path = Round(rf, 2f * scale))
        {
            using var b = new LinearGradientBrush(new RectangleF(r.X, r.Y - 1, r.Width, r.Height + 2), top, bottom, LinearGradientMode.Vertical);
            g.FillPath(b, path);
            using var p = new Pen(border);
            g.DrawPath(p, path);
        }
        // arrow
        float cx = r.X + r.Width / 2f, cy = r.Y + r.Height / 2f;
        float w = Math.Max(3f, Math.Min(r.Width, r.Height) * 0.26f), h = w * 0.6f;
        PointF[] tri = dir == Arrow.Up
            ? new[] { new PointF(cx - w, cy + h * 0.6f), new PointF(cx, cy - h * 0.9f), new PointF(cx + w, cy + h * 0.6f) }
            : new[] { new PointF(cx - w, cy - h * 0.6f), new PointF(cx, cy + h * 0.9f), new PointF(cx + w, cy - h * 0.6f) };
        using (var ap = new Pen(enabled ? (pressed ? Color.White : ArrowGlyph) : DisabledText, Math.Max(1.6f, 1.9f * scale)) { LineJoin = LineJoin.Round, StartCap = LineCap.Round, EndCap = LineCap.Round })
            g.DrawLines(ap, tri);
        g.SmoothingMode = old;
    }

    public static void Tooltip(ToolTip tip)
    {
        tip.OwnerDraw = true;
        tip.BackColor = TooltipBack;
        tip.ForeColor = Color.Black;
        tip.Popup += (_, e) =>
        {
            var size = TextRenderer.MeasureText(tip.GetToolTip(e.AssociatedControl) ?? "", UiFont, new Size(420, 0), TextFormatFlags.WordBreak);
            e.ToolTipSize = new Size(size.Width + 10, size.Height + 8);
        };
        tip.Draw += (_, e) =>
        {
            using (var b = new SolidBrush(TooltipBack)) e.Graphics.FillRectangle(b, e.Bounds);
            using (var p = new Pen(Color.Black)) e.Graphics.DrawRectangle(p, 0, 0, e.Bounds.Width - 1, e.Bounds.Height - 1);
            var r = new Rectangle(5, 4, e.Bounds.Width - 10, e.Bounds.Height - 8);
            TextRenderer.DrawText(e.Graphics, e.ToolTipText, UiFont, r, Color.Black, TextFormatFlags.WordBreak | TextFormatFlags.Left);
        };
    }
}

// ============================================================================
// Window frame: blue Luna caption, rounded top corners, XP caption buttons
// ============================================================================
internal class XpForm : Form
{
    private const int WM_NCHITTEST = 0x84, WM_GETMINMAXINFO = 0x24;
    private const int HTCLIENT = 1, HTCAPTION = 2, HTLEFT = 10, HTRIGHT = 11, HTTOP = 12, HTTOPLEFT = 13, HTTOPRIGHT = 14,
        HTBOTTOM = 15, HTBOTTOMLEFT = 16, HTBOTTOMRIGHT = 17;

    protected bool CanMaximize = true, CanMinimize = true, CanResize = true;
    private int _hot = -1, _pressed = -1;
    private bool _active = true;

    public XpForm()
    {
        FormBorderStyle = FormBorderStyle.None;
        BackColor = Xp.Face;
        Font = Xp.UiFont;
        DoubleBuffered = true;
        SetStyle(ControlStyles.ResizeRedraw | ControlStyles.OptimizedDoubleBuffer | ControlStyles.AllPaintingInWmPaint, true);
    }

    protected float Dpi => DeviceDpi / 96f;
    protected int Px(float v) => (int)Math.Round(v * Dpi);
    protected int CaptionHeight => Px(30);
    protected int Frame => WindowState == FormWindowState.Maximized ? 0 : Px(4);

    protected override CreateParams CreateParams
    {
        get
        {
            var cp = base.CreateParams;
            cp.Style |= 0x00080000; // WS_SYSMENU: Alt+Space, taskbar menu
            if (CanMinimize) cp.Style |= 0x00020000; // WS_MINIMIZEBOX: minimize from the taskbar
            if (CanMaximize) cp.Style |= 0x00010000; // WS_MAXIMIZEBOX
            return cp;
        }
    }

    protected void UpdateChrome()
    {
        int f = Frame;
        var pad = new Padding(f, CaptionHeight, f, f);
        if (Padding != pad) Padding = pad;
        if (WindowState == FormWindowState.Maximized || Width <= 0 || Height <= 0) Region = null;
        else
        {
            using var path = Xp.RoundTop(new RectangleF(0, 0, Width, Height + 1), Px(7));
            Region = new Region(path);
        }
        Invalidate();
    }

    protected override void OnHandleCreated(EventArgs e) { base.OnHandleCreated(e); UpdateChrome(); }
    protected override void OnSizeChanged(EventArgs e) { base.OnSizeChanged(e); UpdateChrome(); }
    protected override void OnDpiChanged(DpiChangedEventArgs e) { base.OnDpiChanged(e); UpdateChrome(); }
    protected override void OnActivated(EventArgs e) { _active = true; Invalidate(); base.OnActivated(e); }
    protected override void OnDeactivate(EventArgs e) { _active = false; Invalidate(); base.OnDeactivate(e); }
    protected override void OnTextChanged(EventArgs e) { base.OnTextChanged(e); Invalidate(new Rectangle(0, 0, Width, CaptionHeight)); }

    // 0 = close, 1 = maximize / restore, 2 = minimize
    private Rectangle ButtonRect(int which)
    {
        int size = Px(21), gap = Px(2), right = Width - Frame - Px(5);
        int top = (CaptionHeight - size) / 2 + Px(1);
        int slot = which;
        if (which == 2 && !CanMaximize) slot = 1;
        if ((which == 1 && !CanMaximize) || (which == 2 && !CanMinimize)) return Rectangle.Empty;
        return new Rectangle(right - size * (slot + 1) - gap * slot, top, size, size);
    }

    private int ButtonAt(Point p)
    {
        for (int i = 0; i < 3; i++)
            if (ButtonRect(i).Contains(p)) return i;
        return -1;
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        var g = e.Graphics;
        int cap = CaptionHeight, f = Frame;

        // caption
        var capRect = new Rectangle(0, 0, Width, cap);
        using (var b = new LinearGradientBrush(new Rectangle(0, -1, Width, cap + 2), Color.White, Color.White, LinearGradientMode.Vertical))
        {
            b.InterpolationColors = _active
                ? new ColorBlend
                {
                    Colors = new[] { Xp.C(0x3D95FF), Xp.C(0x0A66F5), Xp.C(0x0054E3), Xp.C(0x0058EB), Xp.C(0x0761F4), Xp.C(0x003DD7) },
                    Positions = new[] { 0f, 0.08f, 0.35f, 0.6f, 0.86f, 1f },
                }
                : new ColorBlend
                {
                    Colors = new[] { Xp.C(0xC2D4F6), Xp.C(0xA3BDEE), Xp.C(0x94AFE8), Xp.C(0x9AB4EA), Xp.C(0xA5BDEE), Xp.C(0x8EA9E3) },
                    Positions = new[] { 0f, 0.08f, 0.35f, 0.6f, 0.86f, 1f },
                };
            g.FillRectangle(b, capRect);
        }
        // frame (left, right, bottom)
        if (f > 0)
        {
            Color outer = _active ? Xp.C(0x0019CF) : Xp.C(0x8DA3DA);
            Color mid = _active ? Xp.C(0x0855DD) : Xp.C(0xA8BAEB);
            Color inner = _active ? Xp.C(0x166AEE) : Xp.C(0xB9C9F0);
            using var bm = new SolidBrush(mid);
            g.FillRectangle(bm, 0, cap, f, Height - cap);
            g.FillRectangle(bm, Width - f, cap, f, Height - cap);
            g.FillRectangle(bm, 0, Height - f, Width, f);
            using var po = new Pen(outer);
            g.DrawLine(po, 0, cap / 2, 0, Height - 1);
            g.DrawLine(po, Width - 1, cap / 2, Width - 1, Height - 1);
            g.DrawLine(po, 0, Height - 1, Width - 1, Height - 1);
            using var pi = new Pen(inner);
            g.DrawLine(pi, f - 1, cap, f - 1, Height - f);
            g.DrawLine(pi, Width - f, cap, Width - f, Height - f);
            g.DrawLine(pi, f - 1, Height - f, Width - f, Height - f);
        }

        // icon and title
        int x = f + Px(6);
        int icon = Px(16);
        if (Icon != null)
        {
            try
            {
                using var ic = new Icon(Icon, icon, icon);
                g.DrawIcon(ic, new Rectangle(x, (cap - icon) / 2 + Px(1), icon, icon));
                x += icon + Px(5);
            }
            catch { }
        }
        int buttonsLeft = Width;
        for (int i = 0; i < 3; i++) { var br = ButtonRect(i); if (!br.IsEmpty) buttonsLeft = Math.Min(buttonsLeft, br.Left); }
        var titleRect = new Rectangle(x, Px(1), Math.Max(0, buttonsLeft - x - Px(4)), cap);
        var tf = TextFormatFlags.Left | TextFormatFlags.VerticalCenter | TextFormatFlags.SingleLine | TextFormatFlags.EndEllipsis | TextFormatFlags.NoPrefix;
        if (_active)
        {
            var shadow = titleRect; shadow.Offset(1, 1);
            TextRenderer.DrawText(g, Text, Xp.TitleFont, shadow, Xp.C(0x0A1883), tf);
        }
        TextRenderer.DrawText(g, Text, Xp.TitleFont, titleRect, _active ? Color.White : Xp.C(0xD8E4F8), tf);

        for (int i = 0; i < 3; i++)
        {
            var br = ButtonRect(i);
            if (!br.IsEmpty) DrawCaptionButton(g, br, i);
        }
    }

    private void DrawCaptionButton(Graphics g, Rectangle r, int which)
    {
        bool hot = _hot == which, pressed = _pressed == which && hot;
        bool close = which == 0;
        Color top, bottom;
        if (close)
        {
            if (!_active) { top = Xp.C(0xE8B7A9); bottom = Xp.C(0xD38D78); }
            else if (pressed) { top = Xp.C(0xB23A16); bottom = Xp.C(0xD6603D); }
            else if (hot) { top = Xp.C(0xF9A88D); bottom = Xp.C(0xDA5631); }
            else { top = Xp.C(0xEE9578); bottom = Xp.C(0xC8441C); }
        }
        else
        {
            if (!_active) { top = Xp.C(0xB9CDF4); bottom = Xp.C(0x9AB3EA); }
            else if (pressed) { top = Xp.C(0x1A48C4); bottom = Xp.C(0x4673E7); }
            else if (hot) { top = Xp.C(0x8BB4FF); bottom = Xp.C(0x3E72F2); }
            else { top = Xp.C(0x6699F8); bottom = Xp.C(0x2459DF); }
        }
        var old = g.SmoothingMode;
        g.SmoothingMode = SmoothingMode.AntiAlias;
        var rf = new RectangleF(r.X + 0.5f, r.Y + 0.5f, r.Width - 1, r.Height - 1);
        using (var path = Xp.Round(rf, Px(3)))
        {
            using var b = new LinearGradientBrush(new RectangleF(r.X, r.Y - 1, r.Width, r.Height + 2), top, bottom, LinearGradientMode.ForwardDiagonal);
            g.FillPath(b, path);
            using var p = new Pen(Color.FromArgb(_active ? 255 : 200, Color.White), Math.Max(1f, Dpi));
            g.DrawPath(p, path);
        }
        // glyphs
        Color glyph = _active ? Color.White : Xp.C(0xEEF2FB);
        float s = r.Width / 21f;
        float cx = r.X + r.Width / 2f, cy = r.Y + r.Height / 2f;
        if (which == 0)
        {
            using var p = new Pen(glyph, 2.2f * s) { StartCap = LineCap.Round, EndCap = LineCap.Round };
            float d = 4.2f * s;
            g.DrawLine(p, cx - d, cy - d, cx + d, cy + d);
            g.DrawLine(p, cx + d, cy - d, cx - d, cy + d);
        }
        else if (which == 1)
        {
            g.SmoothingMode = SmoothingMode.None;
            using var b = new SolidBrush(glyph);
            if (WindowState == FormWindowState.Maximized)
            {
                // restore: two overlapping windows
                var back = Rectangle.Round(new RectangleF(cx - 2f * s, cy - 6f * s, 8f * s, 7f * s));
                var front = Rectangle.Round(new RectangleF(cx - 5f * s, cy - 3f * s, 8f * s, 7f * s));
                DrawWindowGlyph(g, b, back, s);
                using (var fill = new LinearGradientBrush(new RectangleF(r.X, r.Y - 1, r.Width, r.Height + 2), top, bottom, LinearGradientMode.ForwardDiagonal))
                    g.FillRectangle(fill, front);
                DrawWindowGlyph(g, b, front, s);
            }
            else
            {
                DrawWindowGlyph(g, b, Rectangle.Round(new RectangleF(cx - 5f * s, cy - 5f * s, 10f * s, 10f * s)), s);
            }
        }
        else
        {
            using var b = new SolidBrush(glyph);
            g.FillRectangle(b, new RectangleF(cx - 4.5f * s, cy + 2.5f * s, 6.5f * s, 2.5f * s));
        }
        g.SmoothingMode = old;
    }

    private static void DrawWindowGlyph(Graphics g, Brush b, Rectangle r, float s)
    {
        int t = Math.Max(1, (int)Math.Round(s));
        g.FillRectangle(b, r.X, r.Y, r.Width, Math.Max(2, (int)Math.Round(2.5f * s)));   // title bar
        g.FillRectangle(b, r.X, r.Y, t, r.Height);
        g.FillRectangle(b, r.Right - t, r.Y, t, r.Height);
        g.FillRectangle(b, r.X, r.Bottom - t, r.Width, t);
    }

    protected override void OnMouseMove(MouseEventArgs e)
    {
        int h = ButtonAt(e.Location);
        if (h != _hot) { _hot = h; Invalidate(new Rectangle(0, 0, Width, CaptionHeight)); }
        base.OnMouseMove(e);
    }

    protected override void OnMouseLeave(EventArgs e)
    {
        if (_hot != -1) { _hot = -1; Invalidate(new Rectangle(0, 0, Width, CaptionHeight)); }
        base.OnMouseLeave(e);
    }

    protected override void OnMouseDown(MouseEventArgs e)
    {
        if (e.Button == MouseButtons.Left)
        {
            _pressed = ButtonAt(e.Location);
            if (_pressed >= 0) { Capture = true; Invalidate(new Rectangle(0, 0, Width, CaptionHeight)); }
        }
        base.OnMouseDown(e);
    }

    protected override void OnMouseUp(MouseEventArgs e)
    {
        int was = _pressed;
        _pressed = -1;
        Capture = false;
        Invalidate(new Rectangle(0, 0, Width, CaptionHeight));
        if (e.Button == MouseButtons.Left && was >= 0 && ButtonAt(e.Location) == was)
        {
            if (was == 0) Close();
            else if (was == 1) WindowState = WindowState == FormWindowState.Maximized ? FormWindowState.Normal : FormWindowState.Maximized;
            else if (was == 2) WindowState = FormWindowState.Minimized;
        }
        base.OnMouseUp(e);
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct POINT { public int X, Y; }

    [StructLayout(LayoutKind.Sequential)]
    private struct MINMAXINFO { public POINT Reserved, MaxSize, MaxPosition, MinTrackSize, MaxTrackSize; }

    protected override void WndProc(ref Message m)
    {
        if (m.Msg == WM_NCHITTEST)
        {
            base.WndProc(ref m);
            long lp = m.LParam.ToInt64();
            var p = PointToClient(new Point((short)(lp & 0xFFFF), (short)((lp >> 16) & 0xFFFF)));
            int hit = HitTest(p);
            if (hit != HTCLIENT) m.Result = (IntPtr)hit;
            return;
        }
        if (m.Msg == WM_GETMINMAXINFO)
        {
            base.WndProc(ref m);
            try
            {
                var mmi = Marshal.PtrToStructure<MINMAXINFO>(m.LParam);
                var screen = Screen.FromHandle(Handle);
                Rectangle wa = screen.WorkingArea, b = screen.Bounds;
                mmi.MaxPosition = new POINT { X = wa.Left - b.Left, Y = wa.Top - b.Top };
                mmi.MaxSize = new POINT { X = wa.Width, Y = wa.Height };
                mmi.MinTrackSize = new POINT { X = MinimumSize.Width, Y = MinimumSize.Height };
                Marshal.StructureToPtr(mmi, m.LParam, false);
            }
            catch { }
            return;
        }
        base.WndProc(ref m);
    }

    private int HitTest(Point p)
    {
        if (CanResize && WindowState == FormWindowState.Normal)
        {
            int grip = Px(5);
            bool l = p.X < grip, r = p.X >= Width - grip, t = p.Y < grip, b = p.Y >= Height - grip;
            if (t && l) return HTTOPLEFT;
            if (t && r) return HTTOPRIGHT;
            if (b && l) return HTBOTTOMLEFT;
            if (b && r) return HTBOTTOMRIGHT;
            if (l) return HTLEFT;
            if (r) return HTRIGHT;
            if (t) return HTTOP;
            if (b) return HTBOTTOM;
        }
        if (p.Y >= 0 && p.Y < CaptionHeight)
            return ButtonAt(p) >= 0 ? HTCLIENT : HTCAPTION;
        return HTCLIENT;
    }
}

// ============================================================================
// Controls
// ============================================================================
internal sealed class XpButton : Button
{
    private bool _hot, _down;

    public XpButton()
    {
        SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw | ControlStyles.SupportsTransparentBackColor, true);
        Font = Xp.UiFont;
        MinimumSize = new Size(75, 23);
        Padding = new Padding(6, 1, 6, 1);
        AutoSize = true;
        AutoSizeMode = AutoSizeMode.GrowAndShrink;
        UseVisualStyleBackColor = false;
        BackColor = Color.Transparent;
    }

    protected override void OnMouseEnter(EventArgs e) { _hot = true; Invalidate(); base.OnMouseEnter(e); }
    protected override void OnMouseLeave(EventArgs e) { _hot = false; Invalidate(); base.OnMouseLeave(e); }
    protected override void OnMouseDown(MouseEventArgs e) { if (e.Button == MouseButtons.Left) { _down = true; Invalidate(); } base.OnMouseDown(e); }
    protected override void OnMouseUp(MouseEventArgs e) { _down = false; Invalidate(); base.OnMouseUp(e); }
    protected override void OnEnabledChanged(EventArgs e) { Invalidate(); base.OnEnabledChanged(e); }
    protected override void OnGotFocus(EventArgs e) { Invalidate(); base.OnGotFocus(e); }
    protected override void OnLostFocus(EventArgs e) { Invalidate(); base.OnLostFocus(e); }

    protected override void OnPaint(PaintEventArgs e)
    {
        var g = e.Graphics;
        Color back = Parent?.BackColor ?? Xp.Face;
        using (var bb = new SolidBrush(back)) g.FillRectangle(bb, ClientRectangle);
        g.SmoothingMode = SmoothingMode.AntiAlias;
        float s = Xp.Scale(this);
        var r = new RectangleF(0.5f, 0.5f, Width - 1.5f, Height - 1.5f);
        bool pressed = _down && _hot;
        using (var path = Xp.Round(r, 3f * s))
        {
            Color top = pressed ? Xp.C(0xE5E4DD) : Color.White;
            Color bottom = pressed ? Xp.C(0xF2F1EE) : Xp.C(0xE3E2DB);
            if (!Enabled) { top = Xp.C(0xF5F4EA); bottom = Xp.C(0xF5F4EA); }
            using (var b = new LinearGradientBrush(new RectangleF(0, -1, Width, Height + 2), top, bottom, LinearGradientMode.Vertical))
                g.FillPath(b, path);
            if (Enabled && !pressed)
            {
                // soft bottom shade
                using var shade = new Pen(Xp.C(0xD6D0C5), Math.Max(1f, s));
                g.DrawLine(shade, 2 * s, Height - 2.5f * s, Width - 2 * s, Height - 2.5f * s);
            }
            if (Enabled && (_hot || Focused || IsDefault))
            {
                // inner glow: orange when hovered, blue when focused / default
                Color a = _hot ? Xp.C(0xFFF0CF) : Xp.C(0xCEE7FF);
                Color z = _hot ? Xp.C(0xF8B330) : Xp.C(0x6982EE);
                var inner = new RectangleF(1.5f * s, 1.5f * s, Width - 3.5f * s - 1, Height - 3.5f * s - 1);
                using var ip = Xp.Round(inner, 2f * s);
                using var gb = new LinearGradientBrush(new RectangleF(0, 0, Width, Height), a, z, LinearGradientMode.Vertical);
                using var pen = new Pen(gb, Math.Max(2f, 2f * s));
                g.DrawPath(pen, ip);
            }
            using var bp = new Pen(Enabled ? Xp.ButtonBorder : Xp.DisabledBorder, Math.Max(1f, s));
            g.DrawPath(bp, path);
        }
        var tr = ClientRectangle;
        if (pressed) tr.Offset(1, 1);
        TextRenderer.DrawText(g, Text, Font, tr, Enabled ? Color.Black : Xp.DisabledText,
            TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.SingleLine);
        if (Focused && ShowFocusCues)
        {
            var fr = Rectangle.Inflate(ClientRectangle, -(int)(4 * s), -(int)(4 * s));
            ControlPaint.DrawFocusRectangle(g, fr, Color.Black, Color.White);
        }
    }
}

internal sealed class XpCheckBox : CheckBox
{
    private bool _hot, _down;

    public XpCheckBox()
    {
        SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
        Font = Xp.UiFont;
        AutoSize = true;
    }

    protected override void OnMouseEnter(EventArgs e) { _hot = true; Invalidate(); base.OnMouseEnter(e); }
    protected override void OnMouseLeave(EventArgs e) { _hot = false; Invalidate(); base.OnMouseLeave(e); }
    protected override void OnMouseDown(MouseEventArgs e) { if (e.Button == MouseButtons.Left) { _down = true; Invalidate(); } base.OnMouseDown(e); }
    protected override void OnMouseUp(MouseEventArgs e) { _down = false; Invalidate(); base.OnMouseUp(e); }

    public override Size GetPreferredSize(Size proposedSize)
    {
        float s = Xp.Scale(this);
        var t = TextRenderer.MeasureText(Text, Font, Size.Empty, TextFormatFlags.SingleLine | TextFormatFlags.NoPadding);
        return new Size((int)(13 * s) + (int)(6 * s) + t.Width + Padding.Horizontal + 2, Math.Max((int)(17 * s), t.Height + 4) + Padding.Vertical);
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        var g = e.Graphics;
        using (var bb = new SolidBrush(Parent?.BackColor ?? BackColor)) g.FillRectangle(bb, ClientRectangle);
        float s = Xp.Scale(this);
        int box = Math.Max(13, (int)Math.Round(13 * s));
        int y = Padding.Top + (Height - Padding.Vertical - box) / 2;
        var br = new Rectangle(Padding.Left, y, box, box);
        Xp.DrawCheckBox(g, br, Checked, _hot, _down && _hot, Enabled);
        var tr = new Rectangle(br.Right + (int)(5 * s), 0, Width - br.Right - (int)(5 * s), Height);
        TextRenderer.DrawText(g, Text, Font, tr, Enabled ? Color.Black : Xp.DisabledText,
            TextFormatFlags.Left | TextFormatFlags.VerticalCenter | TextFormatFlags.SingleLine | TextFormatFlags.NoPadding);
        if (Focused && ShowFocusCues)
        {
            var ts = TextRenderer.MeasureText(Text, Font, Size.Empty, TextFormatFlags.SingleLine | TextFormatFlags.NoPadding);
            var fr = new Rectangle(tr.X - 1, (Height - ts.Height) / 2 - 1, ts.Width + 2, ts.Height + 2);
            ControlPaint.DrawFocusRectangle(g, fr, Color.Black, Color.White);
        }
    }
}

internal sealed class XpGroupBox : GroupBox
{
    public XpGroupBox()
    {
        SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
        Font = Xp.UiFont;
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        var g = e.Graphics;
        Color back = Parent?.BackColor ?? BackColor;
        using (var bb = new SolidBrush(back)) g.FillRectangle(bb, ClientRectangle);
        float s = Xp.Scale(this);
        var ts = TextRenderer.MeasureText(Text, Font, Size.Empty, TextFormatFlags.SingleLine | TextFormatFlags.NoPadding);
        int ty = ts.Height / 2;
        g.SmoothingMode = SmoothingMode.AntiAlias;
        using (var path = Xp.Round(new RectangleF(0.5f, ty + 0.5f, Width - 1.5f, Height - ty - 1.5f), 3f * s))
        using (var p = new Pen(Xp.GroupBorder))
            g.DrawPath(p, path);
        g.SmoothingMode = SmoothingMode.None;
        int tx = (int)(8 * s);
        using (var bb = new SolidBrush(back)) g.FillRectangle(bb, tx - 2, 0, ts.Width + 4, ts.Height);
        TextRenderer.DrawText(g, Text, Font, new Point(tx, 0), Enabled ? Xp.GroupText : Xp.DisabledText, TextFormatFlags.SingleLine | TextFormatFlags.NoPadding);
    }
}

internal sealed class XpTabControl : TabControl
{
    private int _hot = -1;

    public XpTabControl()
    {
        SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
        Font = Xp.UiFont;
        Padding = new Point(12, 4);
    }

    protected override void OnMouseMove(MouseEventArgs e)
    {
        int h = -1;
        for (int i = 0; i < TabCount; i++) if (GetTabRect(i).Contains(e.Location)) h = i;
        if (h != _hot) { _hot = h; Invalidate(); }
        base.OnMouseMove(e);
    }

    protected override void OnMouseLeave(EventArgs e) { _hot = -1; Invalidate(); base.OnMouseLeave(e); }
    protected override void OnSelectedIndexChanged(EventArgs e) { Invalidate(); base.OnSelectedIndexChanged(e); }

    protected override void OnPaint(PaintEventArgs e)
    {
        var g = e.Graphics;
        using (var bb = new SolidBrush(Parent?.BackColor ?? Xp.Face)) g.FillRectangle(bb, ClientRectangle);
        if (TabCount == 0) return;
        float s = Xp.Scale(this);
        int top = GetTabRect(0).Bottom;
        var frame = new Rectangle(0, top, Width - 1, Height - top - 1);
        using (var pb = new LinearGradientBrush(new Rectangle(frame.X, frame.Y - 1, frame.Width + 1, frame.Height + 2), Xp.Page, Xp.C(0xF4F3EE), LinearGradientMode.Vertical))
            g.FillRectangle(pb, frame);
        using (var bp = new Pen(Xp.TabBorder)) g.DrawRectangle(bp, frame);
        for (int i = 0; i < TabCount; i++) if (i != SelectedIndex) DrawTab(g, i, false, s, top);
        if (SelectedIndex >= 0) DrawTab(g, SelectedIndex, true, s, top);
    }

    private void DrawTab(Graphics g, int i, bool sel, float s, int frameTop)
    {
        Rectangle r = GetTabRect(i);
        if (sel) r = new Rectangle(r.X - (int)(2 * s), r.Y - (int)(2 * s), r.Width + (int)(4 * s), frameTop - r.Y + (int)(2 * s) + 1);
        else r = new Rectangle(r.X, r.Y + (int)(1 * s), r.Width, frameTop - r.Y - (int)(1 * s));
        g.SmoothingMode = SmoothingMode.AntiAlias;
        using (var path = Xp.RoundTop(new RectangleF(r.X + 0.5f, r.Y + 0.5f, r.Width - 1, r.Height), 3f * s))
        {
            if (sel) { using var b = new SolidBrush(Xp.Page); g.FillPath(b, path); }
            else
            {
                using var b = new LinearGradientBrush(new Rectangle(r.X, r.Y - 1, r.Width, r.Height + 2),
                    Color.White, i == _hot ? Xp.C(0xF6F5F0) : Xp.C(0xECEBE6), LinearGradientMode.Vertical);
                g.FillPath(b, path);
            }
            using var p = new Pen(Xp.TabBorder);
            g.DrawPath(p, path);
        }
        g.SmoothingMode = SmoothingMode.None;
        if (sel || i == _hot)
        {
            // the orange line on top of the selected / hovered tab
            int t = Math.Max(1, (int)Math.Round(s));
            using var o1 = new SolidBrush(Xp.C(0xE68B2C));
            using var o2 = new SolidBrush(Xp.C(0xFFC73C));
            g.FillRectangle(o1, r.X + (int)(2 * s), r.Y, r.Width - (int)(4 * s), t);
            g.FillRectangle(o2, r.X + 1, r.Y + t, r.Width - 2, 2 * t);
        }
        if (sel)
        {
            using var cover = new Pen(Xp.Page);
            g.DrawLine(cover, r.X + 1, frameTop, r.Right - 2, frameTop);
        }
        var tr = r;
        if (sel) tr.Offset(0, -(int)(1 * s));
        TextRenderer.DrawText(g, TabPages[i].Text, Font, tr, Color.Black,
            TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.SingleLine | TextFormatFlags.NoPrefix);
    }
}

internal sealed class XpNumericUpDown : NumericUpDown
{
    private int _hotHalf = -1, _downHalf = -1;

    public XpNumericUpDown()
    {
        Font = Xp.UiFont;
        BorderStyle = BorderStyle.FixedSingle;
        Control? buttons = null;
        foreach (Control c in Controls) if (c.GetType().Name.Contains("UpDownButtons")) buttons = c;
        if (buttons is Control btns)
        {
            var buttons2 = btns;
            buttons2.Paint += PaintButtons;
            buttons2.MouseMove += (_, e) => { int h = e.Y < buttons2.Height / 2 ? 0 : 1; if (h != _hotHalf) { _hotHalf = h; buttons2.Invalidate(); } };
            buttons2.MouseLeave += (_, _) => { _hotHalf = -1; buttons2.Invalidate(); };
            buttons2.MouseDown += (_, e) => { _downHalf = e.Y < buttons2.Height / 2 ? 0 : 1; buttons2.Invalidate(); };
            buttons2.MouseUp += (_, _) => { _downHalf = -1; buttons2.Invalidate(); };
        }
    }

    private void PaintButtons(object? sender, PaintEventArgs e)
    {
        if (sender is not Control c) return;
        var g = e.Graphics;
        using (var bb = new SolidBrush(Color.White)) g.FillRectangle(bb, c.ClientRectangle);
        float s = Xp.Scale(this);
        int h = c.Height / 2;
        var up = new Rectangle(0, 0, c.Width, h);
        var down = new Rectangle(0, h, c.Width, c.Height - h);
        Xp.DrawArrowButton(g, up, Xp.Arrow.Up, _hotHalf == 0, _downHalf == 0, Enabled, s);
        Xp.DrawArrowButton(g, down, Xp.Arrow.Down, _hotHalf == 1, _downHalf == 1, Enabled, s);
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        base.OnPaint(e);
        using var p = new Pen(Enabled ? Xp.FieldBorder : Xp.DisabledBorder);
        e.Graphics.DrawRectangle(p, 0, 0, Width - 1, Height - 1);
    }
}

internal sealed class XpComboBox : ComboBox
{
    private bool _hot;

    public XpComboBox()
    {
        SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
        DropDownStyle = ComboBoxStyle.DropDownList;
        DrawMode = DrawMode.OwnerDrawFixed;
        Font = Xp.UiFont;
        ItemHeight = 15;
        DrawItem += (_, e) =>
        {
            if (e.Index < 0) return;
            bool sel = (e.State & DrawItemState.Selected) != 0;
            using (var b = new SolidBrush(sel ? Xp.Selection : Color.White)) e.Graphics.FillRectangle(b, e.Bounds);
            TextRenderer.DrawText(e.Graphics, Items[e.Index]?.ToString() ?? "", Xp.UiFont, e.Bounds, sel ? Color.White : Color.Black,
                TextFormatFlags.Left | TextFormatFlags.VerticalCenter | TextFormatFlags.SingleLine);
        };
    }

    protected override void OnMouseEnter(EventArgs e) { _hot = true; Invalidate(); base.OnMouseEnter(e); }
    protected override void OnMouseLeave(EventArgs e) { _hot = false; Invalidate(); base.OnMouseLeave(e); }
    protected override void OnSelectedIndexChanged(EventArgs e) { Invalidate(); base.OnSelectedIndexChanged(e); }
    protected override void OnGotFocus(EventArgs e) { Invalidate(); base.OnGotFocus(e); }
    protected override void OnLostFocus(EventArgs e) { Invalidate(); base.OnLostFocus(e); }
    protected override void OnDropDownClosed(EventArgs e) { Invalidate(); base.OnDropDownClosed(e); }

    protected override void OnPaint(PaintEventArgs e)
    {
        var g = e.Graphics;
        float s = Xp.Scale(this);
        using (var bb = new SolidBrush(Enabled ? Color.White : Xp.C(0xF5F4EA))) g.FillRectangle(bb, ClientRectangle);
        int bw = Math.Max(15, (int)Math.Round(17 * s));
        var btn = new Rectangle(Width - bw - 1, 1, bw, Height - 2);
        Xp.DrawArrowButton(g, btn, Xp.Arrow.Down, _hot || DroppedDown, DroppedDown, Enabled, s);
        var tr = new Rectangle(2, 2, btn.Left - 4, Height - 4);
        bool focus = Focused && !DroppedDown;
        if (focus) { using var sb = new SolidBrush(Xp.Selection); g.FillRectangle(sb, tr); }
        TextRenderer.DrawText(g, SelectedItem?.ToString() ?? "", Font, new Rectangle(tr.X + 1, tr.Y, tr.Width - 1, tr.Height),
            !Enabled ? Xp.DisabledText : focus ? Color.White : Color.Black, TextFormatFlags.Left | TextFormatFlags.VerticalCenter | TextFormatFlags.SingleLine | TextFormatFlags.EndEllipsis);
        if (focus) ControlPaint.DrawFocusRectangle(g, tr, Color.White, Xp.Selection);
        using var p = new Pen(Enabled ? Xp.FieldBorder : Xp.DisabledBorder);
        g.DrawRectangle(p, 0, 0, Width - 1, Height - 1);
    }
}

/// <summary>Text box with the XP field border (#7F9DB9).</summary>
internal sealed class XpTextBox : Panel
{
    public readonly TextBox Box = new() { BorderStyle = BorderStyle.None, Dock = DockStyle.Fill, Font = Xp.UiFont };

    public XpTextBox(int width)
    {
        BackColor = Color.White;
        Padding = new Padding(3, 3, 2, 2);
        Width = width;
        Height = Box.PreferredHeight + 6;
        Controls.Add(Box);
        SetStyle(ControlStyles.ResizeRedraw, true);
    }

    protected override void OnEnabledChanged(EventArgs e)
    {
        base.OnEnabledChanged(e);
        BackColor = Enabled ? Color.White : Xp.C(0xF5F4EA);
        Box.BackColor = BackColor;
        Invalidate();
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        base.OnPaint(e);
        using var p = new Pen(Enabled ? Xp.FieldBorder : Xp.DisabledBorder);
        e.Graphics.DrawRectangle(p, 0, 0, Width - 1, Height - 1);
    }
}

/// <summary>Panel with a 1 px border in the XP field colour (hosts the species list).</summary>
internal sealed class XpBorderPanel : Panel
{
    public XpBorderPanel() { Padding = new Padding(1); SetStyle(ControlStyles.ResizeRedraw, true); }
    protected override void OnPaint(PaintEventArgs e)
    {
        base.OnPaint(e);
        using var p = new Pen(Xp.FieldBorder);
        e.Graphics.DrawRectangle(p, 0, 0, Width - 1, Height - 1);
    }
}

/// <summary>XP vertical scroll bar (blue thumb with grip, blue arrow buttons).</summary>
internal sealed class XpVScrollBar : Control
{
    private int _max = 1, _large = 1, _small = 1, _value;
    private enum Part { None, Up, Down, PageUp, PageDown, Thumb }
    private Part _hot = Part.None, _down = Part.None;
    private int _dragOffset;
    private readonly System.Windows.Forms.Timer _repeat = new() { Interval = 60 };
    private int _repeatDelay;

    public event EventHandler? ValueChanged;

    public XpVScrollBar()
    {
        SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
        SetStyle(ControlStyles.Selectable, false);
        _repeat.Tick += (_, _) =>
        {
            if (_repeatDelay-- > 0) return;
            if ((_down is Part.Up or Part.Down or Part.PageUp or Part.PageDown) && _hot == _down) Step(_down);
        };
    }

    [Browsable(false), DesignerSerializationVisibility(DesignerSerializationVisibility.Hidden)]
    public int Maximum { get => _max; set { _max = Math.Max(1, value); Value = _value; Invalidate(); } }
    [Browsable(false), DesignerSerializationVisibility(DesignerSerializationVisibility.Hidden)]
    public int LargeChange { get => _large; set { _large = Math.Max(1, value); Value = _value; Invalidate(); } }
    /// <summary>How far one click on an arrow goes (1 for a list of rows; pixels for a page).</summary>
    [Browsable(false), DesignerSerializationVisibility(DesignerSerializationVisibility.Hidden)]
    public int SmallChange { get => _small; set => _small = Math.Max(1, value); }
    private int MaxValue => Math.Max(0, _max - _large);

    [Browsable(false), DesignerSerializationVisibility(DesignerSerializationVisibility.Hidden)]
    public int Value
    {
        get => _value;
        set
        {
            int v = Math.Clamp(value, 0, MaxValue);
            if (v == _value) return;
            _value = v;
            Invalidate();
            ValueChanged?.Invoke(this, EventArgs.Empty);
        }
    }

    public void SetSilently(int v) { _value = Math.Clamp(v, 0, MaxValue); Invalidate(); }

    private int ButtonHeight => Math.Min(Width, Height / 3);

    private Rectangle ThumbRect()
    {
        int bh = ButtonHeight;
        int track = Height - 2 * bh;
        if (track <= 0 || MaxValue == 0) return Rectangle.Empty;
        int th = Math.Max((int)(16 * Xp.Scale(this)), (int)((long)track * _large / _max));
        th = Math.Min(th, track);
        int y = bh + (int)((long)(track - th) * _value / MaxValue);
        return new Rectangle(0, y, Width, th);
    }

    private Part PartAt(Point p)
    {
        int bh = ButtonHeight;
        if (p.Y < bh) return Part.Up;
        if (p.Y >= Height - bh) return Part.Down;
        var t = ThumbRect();
        if (t.Contains(p)) return Part.Thumb;
        return p.Y < t.Top ? Part.PageUp : Part.PageDown;
    }

    private void Step(Part p)
    {
        if (p == Part.Up) Value -= _small;
        else if (p == Part.Down) Value += _small;
        else if (p == Part.PageUp) Value -= _large;
        else if (p == Part.PageDown) Value += _large;
    }

    protected override void OnMouseDown(MouseEventArgs e)
    {
        if (e.Button != MouseButtons.Left) return;
        _down = PartAt(e.Location);
        _hot = _down;
        if (_down == Part.Thumb) _dragOffset = e.Y - ThumbRect().Top;
        else if (_down != Part.None) { Step(_down); _repeatDelay = 5; _repeat.Start(); }
        Capture = true;
        Invalidate();
        base.OnMouseDown(e);
    }

    protected override void OnMouseMove(MouseEventArgs e)
    {
        if (_down == Part.Thumb)
        {
            int bh = ButtonHeight, track = Height - 2 * bh, th = ThumbRect().Height;
            int range = Math.Max(1, track - th);
            int y = Math.Clamp(e.Y - _dragOffset - bh, 0, range);
            Value = (int)Math.Round((double)y * MaxValue / range);
        }
        var h = PartAt(e.Location);
        if (h != _hot) { _hot = h; Invalidate(); }
        base.OnMouseMove(e);
    }

    protected override void OnMouseUp(MouseEventArgs e)
    {
        _down = Part.None;
        _repeat.Stop();
        Capture = false;
        Invalidate();
        base.OnMouseUp(e);
    }

    protected override void OnMouseLeave(EventArgs e) { _hot = Part.None; Invalidate(); base.OnMouseLeave(e); }

    protected override void OnPaint(PaintEventArgs e)
    {
        var g = e.Graphics;
        float s = Xp.Scale(this);
        // track: light with a subtle edge
        Xp.VGradient(g, ClientRectangle, Xp.C(0xF3F1EC), Xp.C(0xFEFEFB));
        using (var tp = new Pen(Xp.C(0xEEEDE5))) g.DrawLine(tp, 0, 0, 0, Height);
        int bh = ButtonHeight;
        Xp.DrawArrowButton(g, new Rectangle(0, 0, Width, bh), Xp.Arrow.Up, _hot == Part.Up, _down == Part.Up && _hot == Part.Up, Enabled, s);
        Xp.DrawArrowButton(g, new Rectangle(0, Height - bh, Width, bh), Xp.Arrow.Down, _hot == Part.Down, _down == Part.Down && _hot == Part.Down, Enabled, s);
        var t = ThumbRect();
        if (t.IsEmpty) return;
        g.SmoothingMode = SmoothingMode.AntiAlias;
        bool hot = _hot == Part.Thumb || _down == Part.Thumb;
        var rf = new RectangleF(t.X + 0.5f, t.Y + 0.5f, t.Width - 1.5f, t.Height - 1.5f);
        using (var path = Xp.Round(rf, 2.5f * s))
        {
            using var b = new LinearGradientBrush(new RectangleF(t.X - 1, t.Y, t.Width + 2, t.Height), hot ? Xp.C(0xDAE6FE) : Xp.C(0xC9DAFC), hot ? Xp.C(0xB4CDFC) : Xp.C(0xA9C2F8), LinearGradientMode.Horizontal);
            g.FillPath(b, path);
            using var p = new Pen(hot ? Xp.C(0x98B1E9) : Xp.C(0xA4B9EC));
            g.DrawPath(p, path);
        }
        g.SmoothingMode = SmoothingMode.None;
        // grip: four short lines in the middle
        if (t.Height > 14 * s)
        {
            int cx = t.X + t.Width / 2, cy = t.Y + t.Height / 2;
            int half = (int)(3.5f * s);
            using var light = new Pen(Xp.C(0xEEF4FE));
            using var dark = new Pen(Xp.C(0x8CB0F8));
            for (int k = -2; k < 2; k++)
            {
                int y = cy + k * (int)Math.Max(2, 2 * s);
                g.DrawLine(light, cx - half, y, cx + half - 1, y);
                g.DrawLine(dark, cx - half + 1, y + 1, cx + half, y + 1);
            }
        }
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing) _repeat.Dispose();
        base.Dispose(disposing);
    }
}

/// <summary>
/// A panel whose content scrolls up and down with the XP scroll bar when it is higher than the
/// panel (the pages made from the modules' schemas). The content is a TableLayoutPanel with one
/// column, AutoSize rows and one last row that takes whatever height is left over: its height is
/// what its rows need at the panel's width.
/// </summary>
internal sealed class XpScrollPanel : Panel
{
    private readonly XpVScrollBar _bar = new() { Visible = false };
    private TableLayoutPanel? _content;
    private readonly List<(Label Label, int Inset)> _wrapped = new();
    private bool _arranging;
    private bool _scrolls;      // (not the bar's Visible: that is false for every control of a tab that is not shown)

    public XpScrollPanel()
    {
        SetStyle(ControlStyles.ResizeRedraw, true);
        _bar.ValueChanged += (_, _) =>
        {
            if (_content == null || _arranging) return;
            _arranging = true;      // moving the content is no reason to lay it out again
            try { _content.Top = -_bar.Value; }
            finally { _arranging = false; }
        };
        Controls.Add(_bar);
    }

    /// <summary>The scroll bar (shown while the content is higher than the panel).</summary>
    public XpVScrollBar Bar => _bar;

    /// <summary>The content is higher than the panel: the scroll bar is there.</summary>
    public bool Scrolls => _scrolls;

    /// <summary>How far the content is scrolled, in pixels.</summary>
    public int Offset => _scrolls ? _bar.Value : 0;

    /// <summary>The height the content needs at the panel's width.</summary>
    public int ContentHeight { get; private set; }

    public void SetContent(TableLayoutPanel content)
    {
        _content = content;
        content.Dock = DockStyle.None;
        content.AutoSize = false;
        content.Anchor = AnchorStyles.Top | AnchorStyles.Left;
        content.Location = Point.Empty;
        Controls.Add(content);
        Arrange();
    }

    /// <summary>
    /// A label whose text wraps at the panel's width less `inset` pixels (at 96 dpi). The inset must be
    /// larger than everything that stands between the panel's edges and the label (paddings, margins,
    /// the frame of a group box): a label that is told to be wider than its cell loses its last line.
    /// </summary>
    public void Wrap(Label label, int inset) => _wrapped.Add((label, inset));

    protected override void OnLayout(LayoutEventArgs levent)
    {
        base.OnLayout(levent);
        Arrange();
    }

    // The height the rows need at this width: laid out for real, then all rows but the last (the filler) added up.
    private int Measure(int width)
    {
        float scale = Xp.Scale(this);
        foreach (var (label, inset) in _wrapped)
        {
            var max = new Size(Math.Max(120, width - (int)Math.Ceiling(inset * scale)), 0);
            if (label.MaximumSize != max) label.MaximumSize = max;
        }
        if (_content!.Width != width) _content.Width = width;
        _content.PerformLayout();
        int[] rows = _content.GetRowHeights();
        int height = _content.Padding.Vertical;
        for (int i = 0; i < rows.Length - 1; i++) height += rows[i];
        return height;
    }

    /// <summary>Lays the content out for the panel's size and shows or hides the scroll bar.</summary>
    public void Arrange()
    {
        if (_arranging || _content == null) return;
        int width = ClientSize.Width, height = ClientSize.Height;
        if (width <= 0 || height <= 0) return;
        _arranging = true;
        try
        {
            int barWidth = Math.Min(SystemInformation.VerticalScrollBarWidth, Math.Max(1, width / 2));
            int needed = Measure(width);
            bool scroll = needed > height;
            int contentWidth = width;
            if (scroll)
            {
                contentWidth = width - barWidth;
                needed = Math.Max(Measure(contentWidth), height + 1);
            }
            ContentHeight = needed;
            if (scroll)
            {
                float scale = Xp.Scale(this);
                _bar.SetBounds(width - barWidth, 0, barWidth, height);
                _bar.Maximum = needed;
                _bar.LargeChange = height;
                _bar.SmallChange = Math.Max(1, (int)(24 * scale));
                _bar.Value = _bar.Value;        // back into the range
            }
            else _bar.SetSilently(0);
            _scrolls = scroll;
            _bar.Visible = scroll;
            _content.SetBounds(0, scroll ? -_bar.Value : 0, contentWidth, Math.Max(needed, height));
        }
        finally { _arranging = false; }
    }

    /// <summary>Scrolls by a mouse wheel movement (120 = one notch).</summary>
    public void ScrollByWheel(int delta)
    {
        if (!_scrolls || delta == 0) return;
        int notch = Math.Max(1, (int)(72 * Xp.Scale(this)));
        _bar.Value -= delta * notch / 120;
    }

    /// <summary>Scrolls so far that the content is `offset` pixels up.</summary>
    public void ScrollTo(int offset)
    {
        if (_scrolls) _bar.Value = offset;
    }

    protected override void OnMouseWheel(MouseEventArgs e)
    {
        if (e is HandledMouseEventArgs h) h.Handled = true;
        ScrollByWheel(e.Delta);
        base.OnMouseWheel(e);
    }

    /// <summary>Scrolls so that a control of the content can be seen (the control that got the focus).</summary>
    public void EnsureVisible(Control control)
    {
        if (_content == null || !_scrolls) return;
        int top = 0;
        Control? c = control;
        while (c != null && c != _content) { top += c.Top; c = c.Parent; }
        if (c == null) return;
        // only a control that is cut off moves the page (one that is all there stays where the mouse just clicked it)
        int margin = (int)(8 * Xp.Scale(this)), bottom = top + control.Height;
        if (top < _bar.Value) _bar.Value = top - margin;
        else if (bottom > _bar.Value + ClientSize.Height) _bar.Value = bottom + margin - ClientSize.Height;
    }
}

// ============================================================================
// Message box in the same style
// ============================================================================
internal sealed class XpMessageBox : XpForm
{
    private XpMessageBox(string text, string caption, MessageBoxButtons buttons, MessageBoxIcon icon)
    {
        CanMaximize = false;
        CanMinimize = false;
        CanResize = false;
        Text = caption;
        ShowInTaskbar = false;
        StartPosition = FormStartPosition.CenterParent;
        AutoScaleDimensions = new SizeF(96F, 96F);
        AutoScaleMode = AutoScaleMode.Dpi;

        var layout = new TableLayoutPanel { ColumnCount = 2, RowCount = 2, AutoSize = true, AutoSizeMode = AutoSizeMode.GrowAndShrink, Padding = new Padding(12, 12, 12, 8), Dock = DockStyle.Fill };
        var iconBox = new PictureBox { Size = new Size(32, 32), Margin = new Padding(0, 0, 12, 0) };
        Icon? sys = icon switch
        {
            MessageBoxIcon.Warning => SystemIcons.Warning,
            MessageBoxIcon.Error => SystemIcons.Error,
            MessageBoxIcon.Question => SystemIcons.Question,
            MessageBoxIcon.Information => SystemIcons.Information,
            _ => null,
        };
        if (sys != null) iconBox.Image = sys.ToBitmap();
        var label = new Label { Text = text, AutoSize = true, MaximumSize = new Size(440, 0), Font = Xp.UiFont, Margin = new Padding(0, 4, 0, 12) };
        layout.Controls.Add(iconBox, 0, 0);
        layout.Controls.Add(label, 1, 0);
        var flow = new FlowLayoutPanel { AutoSize = true, WrapContents = false, Anchor = AnchorStyles.None };
        void add(string t, DialogResult r)
        {
            var b = new XpButton { Text = t, DialogResult = r, Margin = new Padding(4, 0, 4, 0) };
            flow.Controls.Add(b);
            if (AcceptButton == null) AcceptButton = b;
            if (r == DialogResult.Cancel || r == DialogResult.No) CancelButton = b;
        }
        switch (buttons)
        {
            case MessageBoxButtons.OKCancel: add("OK", DialogResult.OK); add("Cancel", DialogResult.Cancel); break;
            case MessageBoxButtons.YesNo: add("Yes", DialogResult.Yes); add("No", DialogResult.No); break;
            case MessageBoxButtons.YesNoCancel: add("Yes", DialogResult.Yes); add("No", DialogResult.No); add("Cancel", DialogResult.Cancel); CancelButton = flow.Controls[2] as IButtonControl; break;
            default: add("OK", DialogResult.OK); CancelButton = AcceptButton; break;
        }
        layout.Controls.Add(flow, 0, 1);
        layout.SetColumnSpan(flow, 2);
        Controls.Add(layout);

        var pref = layout.GetPreferredSize(new Size(600, 0));
        ClientSize = new Size(Math.Max(pref.Width + Px(8) + Padding.Horizontal, Px(280)), pref.Height + CaptionHeight + Px(4) + Px(6));
    }

    public static DialogResult Show(IWin32Window? owner, string text, string caption, MessageBoxButtons buttons, MessageBoxIcon icon)
    {
        using var box = new XpMessageBox(text, caption, buttons, icon);
        return owner != null ? box.ShowDialog(owner) : box.ShowDialog();
    }
}
