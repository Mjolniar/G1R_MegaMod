"""Draws the pictures of the map pins' drawn look (module markers, PinLook = "drawn"): pins, group badges, the
backdrop of a group's list, the colour key and the names, in the look of the game's own maps - sepia ink on
parchment with watercolour washes. Every picture has the size of its classic one (Scripts/Assets/...), so the
module lays them out the same way. Deterministic: the same input gives the same files.

Windows Python with Pillow and numpy:
  python drawn.py --fonts <folder> --npcs <npcs.lua> --out <modules/markers/Scripts/Assets/Drawn> [--only pins,pools,...]
--fonts: a folder with the game's NotoSerif-Regular.ufont / NotoSerif-Bold.ufont / NotoSerif-Italic.ufont (read from
the game's paks; they are open fonts and stay outside the mod - only the pictures made with them ship) and, for the
blackletter names, Windows' Old English Text MT (--blackletter; default OLDENGL.TTF in the Fonts folder of %WINDIR%).
"""
import argparse
import hashlib
import math
import os
import re

import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageFont

SS = 4                                  # drawn at four times the size, then scaled down
INK = (43, 29, 18)                      # sepia ink of the map's lines
PARCHMENT = (241, 229, 200)             # the map's light paper
PIGMENTS = {                            # watercolour washes, deeper than the map's own so that a pin stands out
    "teacher": (40, 78, 150),           # woad / indigo blue
    "trader": (214, 152, 30),           # ochre gold
    "other": (178, 44, 30),             # red ochre (the map's roofs, deeper)
    "orc": (38, 118, 58),               # verdigris green
}


def rng_for(name):
    return np.random.default_rng(int(hashlib.sha256(name.encode("utf-8")).hexdigest()[:12], 16))


def smooth_noise(rng, n, harmonics=4, amp=1.0):
    """a closed wobble around a circle: n values, low frequencies only"""
    t = np.linspace(0, 2 * math.pi, n, endpoint=False)
    out = np.zeros(n)
    for k in range(1, harmonics + 1):
        out += rng.normal(0, amp / k) * np.cos(k * t + rng.uniform(0, 2 * math.pi))
    return out


def grain(rng, size, scale=6):
    """paper-like granulation: noise, blurred a little"""
    g = rng.random((size // scale + 2, size // scale + 2))
    img = Image.fromarray((g * 255).astype(np.uint8)).resize((size, size), Image.BICUBIC)
    return np.asarray(img).astype(float) / 255.0


def wash(rng, size, cx, cy, r, color, alpha=0.9, split=None):
    """a watercolour blob: uneven rim, darker at the edge, granulation; split = second colour for the right half"""
    yy, xx = np.mgrid[0:size, 0:size].astype(float)
    ang = np.arctan2(yy - cy, xx - cx)
    wob = smooth_noise(rng, 720, 5, 0.035)
    idx = ((ang + math.pi) / (2 * math.pi) * 720).astype(int) % 720
    rr = r * (1 + wob[idx])
    d = np.hypot(xx - cx, yy - cy)
    inside = np.clip((rr - d) / (SS * 1.2), 0, 1)                 # soft edge
    rim = np.clip(1 - (rr - d) / (r * 0.28), 0, 1) * inside       # the dried edge is darker
    g = grain(rng, size)
    a = inside * alpha * (0.88 + 0.12 * g) * (1 + 0.18 * rim)
    a = np.clip(a, 0, 1)
    col = np.zeros((size, size, 3))
    base = np.array(color, float)
    col[:] = base
    if split is not None:
        edge = (xx - cx) + (yy - cy) * 0.35 + smooth_noise(rng, size, 3, r * 0.06)[yy.astype(int)]
        right = np.clip(edge / (SS * 1.5) + 0.5, 0, 1)[..., None]
        col = base * (1 - right) + np.array(split, float) * right
    darker = 1 - 0.22 * rim[..., None] - 0.08 * (g[..., None] - 0.5)
    col = np.clip(col * darker, 0, 255)
    return col, a


def stroke(size, points, widths, color, alpha=0.95):
    """a pen line along points (x, y) with a width per point, as an alpha layer"""
    layer = Image.new("L", (size, size), 0)
    d = ImageDraw.Draw(layer)
    for i in range(len(points) - 1):
        (x0, y0), (x1, y1) = points[i], points[i + 1]
        w = (widths[i] + widths[i + 1]) / 2
        d.line([(x0, y0), (x1, y1)], fill=255, width=max(1, int(round(w))))
        d.ellipse([x1 - w / 2, y1 - w / 2, x1 + w / 2, y1 + w / 2], fill=255)
    a = np.asarray(layer).astype(float) / 255.0 * alpha
    col = np.zeros((size, size, 3))
    col[:] = np.array(color, float)
    return col, a


def ring(rng, size, cx, cy, r, width, turns=1.12, wobble=0.025):
    """a circle drawn by hand: starts somewhere, goes a little past its start, thinner at both ends"""
    n = 400
    start = rng.uniform(0, 2 * math.pi)
    t = np.linspace(0, 2 * math.pi * turns, n)
    wob = smooth_noise(rng, n, 4, wobble)
    rr = r * (1 + wob + 0.012 * np.sin(t * 3 + rng.uniform(0, 6)))
    pts = [(cx + rr[i] * math.cos(start + t[i]), cy + rr[i] * math.sin(start + t[i])) for i in range(n)]
    s = np.linspace(0, 1, n)
    press = np.clip(np.minimum(s / 0.12, (1 - s) / 0.12), 0.25, 1.0)          # the pen lands and lifts
    widths = width * press * (0.9 + 0.2 * rng.random(n))
    return stroke(size, pts, widths, INK)


def halo(size, cx, cy, r, alpha=0.6):
    """a soft patch of light paper behind a mark, so that it stands out on dark or busy parts of the map"""
    yy, xx = np.mgrid[0:size, 0:size].astype(float)
    d = np.hypot(xx - cx, yy - cy) / r
    a = np.clip(1 - d, 0, 1) ** 0.6 * alpha
    col = np.zeros((size, size, 3))
    col[:] = np.array(PARCHMENT, float)
    return col, a


def over(dst_c, dst_a, src_c, src_a):
    """src over dst (straight alpha)"""
    out_a = src_a + dst_a * (1 - src_a)
    safe = np.where(out_a > 1e-6, out_a, 1)
    out_c = (src_c * src_a[..., None] + dst_c * (dst_a * (1 - src_a))[..., None]) / safe[..., None]
    return out_c, out_a


def finish(col, a, size_out):
    rgba = np.dstack([np.clip(col, 0, 255), np.clip(a, 0, 1) * 255]).astype(np.uint8)
    img = Image.fromarray(rgba, "RGBA")
    # premultiplied scaling, so that the edges keep their colour
    pre = np.asarray(img).astype(float)
    pre[..., :3] *= pre[..., 3:4] / 255.0
    small = Image.fromarray(pre.astype(np.uint8), "RGBA").resize((size_out, size_out), Image.LANCZOS)
    s = np.asarray(small).astype(float)
    alpha = s[..., 3:4]
    s[..., :3] = np.where(alpha > 0, s[..., :3] * 255.0 / np.maximum(alpha, 1), 0)
    return Image.fromarray(np.clip(s, 0, 255).astype(np.uint8), "RGBA")


def pin(kind, out_size=64, name=None):
    size = out_size * SS
    rng = rng_for(name or kind)
    c = size / 2
    col = np.zeros((size, size, 3))
    a = np.zeros((size, size))
    hc, ha = halo(size, c, c, size * 0.5, 0.75)
    col, a = over(col, a, hc, ha)
    if kind == "both":
        wc, wa = wash(rng, size, c, c, size * 0.30, PIGMENTS["teacher"], 0.92, split=PIGMENTS["trader"])
    else:
        wc, wa = wash(rng, size, c + rng.uniform(-1, 1) * SS, c + rng.uniform(-1, 1) * SS, size * 0.30, PIGMENTS[kind], 0.92)
    col, a = over(col, a, wc, wa)
    rc, ra = ring(rng, size, c, c, size * 0.355, size * 0.1)
    col, a = over(col, a, rc, ra)
    return finish(col, a, out_size)


PAPER_LIGHT = (247, 239, 216)           # the inside of a badge: lighter than the map, so that the number reads
EDGE = (59, 42, 26)                     # the frame of a group's list


def text_alpha(size_xy, text, font, xy, anchor="la"):
    layer = Image.new("L", size_xy, 0)
    ImageDraw.Draw(layer).text(xy, text, font=font, fill=255, anchor=anchor)
    return np.asarray(layer).astype(float) / 255.0


def pool(label, fonts, out_size=96):
    """a group badge: light paper in a double ink ring, the number written in ink"""
    size = out_size * SS
    rng = rng_for("pool_" + label)
    c = size / 2
    col = np.zeros((size, size, 3))
    a = np.zeros((size, size))
    hc, ha = halo(size, c, c, size * 0.5, 0.7)
    col, a = over(col, a, hc, ha)
    wc, wa = wash(rng, size, c, c, size * 0.41, PAPER_LIGHT, 0.97)
    col, a = over(col, a, wc, wa)
    for r, w in ((0.425, 0.072), (0.352, 0.024)):
        rc, ra = ring(rng, size, c, c, size * r, size * w)
        col, a = over(col, a, rc, ra)
    fsize = size * (0.44 if len(label) <= 2 else 0.34)
    font = ImageFont.truetype(os.path.join(fonts, "NotoSerif-Bold.ufont"), int(fsize))
    ta = text_alpha((size, size), label, font, (c, c + size * 0.01), anchor="mm")
    tc = np.zeros((size, size, 3))
    tc[:] = np.array(INK, float)
    col, a = over(col, a, tc, ta * 0.96)
    return finish(col, a, out_size)


def flat(color, alpha, size=8):
    return Image.new("RGBA", (size, size), tuple(color) + (int(round(alpha * 255)),))


def strip_shape(rng, w, h, inset):
    """a strip of paper with slightly uneven edges (alpha at the size w x h)"""
    yy, xx = np.mgrid[0:h, 0:w].astype(float)
    top = inset + smooth_noise(rng, w, 6, inset * 0.25)[xx.astype(int)]
    bottom = h - inset + smooth_noise(rng, w, 6, inset * 0.25)[xx.astype(int)]
    left = inset + smooth_noise(rng, h, 4, inset * 0.3)[yy.astype(int)]
    right = w - inset + smooth_noise(rng, h, 4, inset * 0.3)[yy.astype(int)]
    edge = np.minimum.reduce([yy - top, bottom - yy, xx - left, right - xx])
    return np.clip(edge / SS + 0.5, 0, 1), edge


def legend(fonts, pins_dir, out_w=1114, out_h=44):
    """the colour key: a strip of parchment with an ink frame, the drawn pins and their names"""
    w, h = out_w * SS, out_h * SS
    rng = rng_for("legend")
    inside, edge = strip_shape(rng, w, h, 3 * SS)
    g = grain(rng, max(w, h))[:h, :w]
    col = np.zeros((h, w, 3))
    col[:] = np.array(PARCHMENT, float)
    col *= (0.97 + 0.06 * (g[..., None] - 0.5))
    a = inside * 0.95
    frame = np.clip(1 - np.abs(edge - 2.2 * SS) / (0.9 * SS), 0, 1) * inside
    fc = np.zeros((h, w, 3))
    fc[:] = np.array(INK, float)
    col, a = over(col, a, fc, frame * 0.85)
    regular = ImageFont.truetype(os.path.join(fonts, "NotoSerif-Regular.ufont"), 22 * SS)
    italic = ImageFont.truetype(os.path.join(fonts, "NotoSerif-Italic.ufont"), 22 * SS)
    items = [("pin_teacher", "Teacher"), ("pin_merchant", "Trader"), ("pin_both", "Teacher + Trader"), ("pin_other", "Other"),
             ("pin_orc", "Orc"), (None, "Group")]
    icon = 26 * SS
    widths = [icon + 8 * SS + regular.getlength(t) for _, t in items]
    hint = "hover for names"
    hint_w = italic.getlength(hint)
    room = w - 2 * 14 * SS - sum(widths) - hint_w
    gap = room / len(items)
    x = 14 * SS
    cy = h / 2
    layer = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    for (fn, t), iw in zip(items, widths):
        if fn:
            im = Image.open(os.path.join(pins_dir, fn + ".png")).convert("RGBA").resize((icon, icon), Image.LANCZOS)
        else:
            im = pool("7", fonts).resize((icon, icon), Image.LANCZOS)
        layer.alpha_composite(im, (int(x), int(cy - icon / 2)))
        ta = text_alpha((w, h), t, regular, (x + icon + 8 * SS, cy + 1 * SS), anchor="lm")
        tc = np.zeros((h, w, 3))
        tc[:] = np.array(INK, float)
        col, a = over(col, a, tc, ta * 0.95)
        x += iw + gap
    ta = text_alpha((w, h), hint, italic, (w - 14 * SS - hint_w, cy + 1 * SS), anchor="lm")
    tc = np.zeros((h, w, 3))
    tc[:] = np.array(INK, float)
    col, a = over(col, a, tc, ta * 0.7)
    la = np.asarray(layer).astype(float)
    col, a = over(col, a, la[..., :3], la[..., 3] / 255.0)
    rgba = np.dstack([np.clip(col, 0, 255), np.clip(a, 0, 1) * 255]).astype(np.uint8)
    pre = rgba.astype(float)
    pre[..., :3] *= pre[..., 3:4] / 255.0
    small = Image.fromarray(pre.astype(np.uint8), "RGBA").resize((out_w, out_h), Image.LANCZOS)
    s = np.asarray(small).astype(float)
    al = s[..., 3:4]
    s[..., :3] = np.where(al > 0, s[..., :3] * 255.0 / np.maximum(al, 1), 0)
    return Image.fromarray(np.clip(s, 0, 255).astype(np.uint8), "RGBA")


PREFIXES = {"teacher": "(T)- ", "trader": "(M)- ", "both": "(T/M)- "}
LS = 2                                  # names are drawn at twice the size


def name_picture(text, font_path, font_size, h=49, pad=15, grow=6):
    """a name in ink on a patch of cleared paper (as names on old maps): 49 pixels high, as wide as it needs"""
    font = ImageFont.truetype(font_path, font_size * LS)
    tw = font.getlength(text)
    W, H = int(math.ceil(tw / LS)) + 2 * pad, h
    w, hh = W * LS, H * LS
    ta = text_alpha((w, hh), text, font, (pad * LS, hh / 2 + 1 * LS), anchor="lm")
    m = Image.fromarray((ta * 255).astype(np.uint8), "L").filter(ImageFilter.MaxFilter(2 * grow * LS + 1))
    m = m.filter(ImageFilter.GaussianBlur(3 * LS))
    paper = np.clip(np.asarray(m).astype(float) / 255.0 * 1.25, 0, 1) * 0.82
    col = np.zeros((hh, w, 3))
    col[:] = np.array(PARCHMENT, float)
    a = paper
    tc = np.zeros((hh, w, 3))
    tc[:] = np.array(INK, float)
    col, a = over(col, a, tc, ta * 0.97)
    rgba = np.dstack([np.clip(col, 0, 255), np.clip(a, 0, 1) * 255]).astype(np.uint8)
    pre = rgba.astype(float)
    pre[..., :3] *= pre[..., 3:4] / 255.0
    small = Image.fromarray(pre.astype(np.uint8), "RGBA").resize((W, H), Image.LANCZOS)
    s = np.asarray(small).astype(float)
    al = s[..., 3:4]
    s[..., :3] = np.where(al > 0, s[..., :3] * 255.0 / np.maximum(al, 1), 0)
    return Image.fromarray(np.clip(s, 0, 255).astype(np.uint8), "RGBA")


def npc_names(npcs):
    text = open(npcs, encoding="utf-8").read()
    out = []
    for m in re.finditer(r'name = "([^"]+)", kind = "([a-z]+)"[^\n]*?label = "Assets/Labels/([^"]+)"', text):
        out.append((PREFIXES.get(m.group(2), "") + m.group(1), m.group(3)))
    return out


def write(img, path):
    """saved as RGBA (the kind of PNG the game is known to load from a mod), its colours reduced to 128 so that the
    files stay small (the difference is a few steps of 255, not to be seen at the size the map shows them)"""
    os.makedirs(os.path.dirname(path), exist_ok=True)
    if img.width > 8:
        img = img.quantize(128, method=Image.Quantize.FASTOCTREE).convert("RGBA")
    img.save(path, optimize=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--fonts")
    ap.add_argument("--npcs")
    ap.add_argument("--out", required=True)
    ap.add_argument("--only", default="pins,pools,list,legend,names")
    ap.add_argument("--weight", default="Bold", help="the weight of Noto Serif for the names (Regular / Bold)")
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--blackletter", default=os.path.join(os.environ.get("WINDIR", ""), "Fonts", "OLDENGL.TTF"))
    args = ap.parse_args()
    only = set(args.only.split(","))
    if "pins" in only:
        for kind, fn in (("teacher", "pin_teacher"), ("trader", "pin_merchant"), ("both", "pin_both"), ("other", "pin_other"), ("orc", "pin_orc")):
            write(pin(kind, name=fn), os.path.join(args.out, "Pins", fn + ".png"))
        print("pins written")
    if "pools" in only:
        for n in range(2, 100):
            write(pool(str(n), args.fonts), os.path.join(args.out, "Pools", "pool_%d.png" % n))
        write(pool("99+", args.fonts), os.path.join(args.out, "Pools", "pool_more.png"))
        print("pools written")
    if "list" in only:
        write(flat(EDGE, 1.0), os.path.join(args.out, "Pools", "list_edge.png"))
        write(flat(PARCHMENT, 0.96), os.path.join(args.out, "Pools", "list_fill.png"))
        print("list backdrop written")
    if "legend" in only:
        write(legend(args.fonts, os.path.join(args.out, "Pins")), os.path.join(args.out, "legend.png"))
        print("legend written")
    if "names" in only:
        names = npc_names(args.npcs)
        if args.limit:
            names = names[:args.limit]
        noto = os.path.join(args.fonts, "NotoSerif-%s.ufont" % args.weight)
        for text, fn in names:
            write(name_picture(text, noto, 24), os.path.join(args.out, "Labels", fn))
            write(name_picture(text, args.blackletter, 27), os.path.join(args.out, "LabelsGothic", fn))
        print("%d names written (twice)" % len(names))


if __name__ == "__main__":
    main()
