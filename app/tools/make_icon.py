"""Draws the icon of the G1R_MegaMod settings app in the style of Windows XP icons: a steel gear (settings) with a
cluster of blue ore crystals (the mod), light from the upper left, soft outlines in darker shades of the fill,
a soft drop shadow. Every size is drawn on its own (thicker lines and fewer parts for the small ones), not scaled
down from the large one.

    python3 make_icon.py <out folder>      writes megamod.ico, megamod-<size>.png and sheet.png (for looking at)
"""
import math
import os
import struct
import sys
import io

import numpy as np
from PIL import Image, ImageChops, ImageDraw, ImageFilter
from scipy import ndimage

SS = 4                      # the drawing space is 256 units wide; drawn at 4 x that
W = 256 * SS


def P(v):
    return v * SS


# ---------------------------------------------------------------------------------------------------------------
# masks
# ---------------------------------------------------------------------------------------------------------------
def new_mask():
    return Image.new("L", (W, W), 0)


def poly_mask(points):
    m = new_mask()
    ImageDraw.Draw(m).polygon([(P(x), P(y)) for x, y in points], fill=255)
    return m


def circle(draw, cx, cy, r, fill):
    draw.ellipse([P(cx - r), P(cy - r), P(cx + r), P(cy + r)], fill=fill)


def rounded(mask, radius):
    """Rounds every corner of a mask (radius in units)."""
    if radius <= 0:
        return mask
    return mask.filter(ImageFilter.GaussianBlur(P(radius))).point(lambda p: 255 if p > 127 else 0)


def erode(mask, width):
    """The mask without a band of `width` units along its edge (exact distances: corners stay as they are)."""
    if width <= 0:
        return mask
    inside = np.asarray(mask) > 127
    dist = ndimage.distance_transform_edt(inside)
    return Image.fromarray((np.clip(dist - P(width) + 0.5, 0, 1) * 255).astype(np.uint8), "L")


def shift(mask, dx, dy):
    out = new_mask()
    out.paste(mask, (int(P(dx)), int(P(dy))))
    return out


def minus(a, b):
    return ImageChops.subtract(a, b)


def both(a, b):
    return ImageChops.multiply(a, b)


# ---------------------------------------------------------------------------------------------------------------
# paint
# ---------------------------------------------------------------------------------------------------------------
def hexrgb(h):
    h = h.lstrip("#")
    return tuple(int(h[i:i + 2], 16) for i in (0, 2, 4))


def gradient(p0, p1, stops):
    """A linear gradient over the whole canvas from point p0 to p1 (units); stops: [(t, "#rrggbb"), ...]."""
    ys, xs = np.mgrid[0:W, 0:W].astype(np.float32)
    x0, y0, x1, y1 = P(p0[0]), P(p0[1]), P(p1[0]), P(p1[1])
    dx, dy = x1 - x0, y1 - y0
    t = ((xs - x0) * dx + (ys - y0) * dy) / (dx * dx + dy * dy)
    t = np.clip(t, 0, 1)
    ts = np.array([s[0] for s in stops], dtype=np.float32)
    cols = np.array([hexrgb(s[1]) for s in stops], dtype=np.float32)
    out = np.zeros((W, W, 3), dtype=np.float32)
    for c in range(3):
        out[..., c] = np.interp(t, ts, cols[:, c])
    return Image.fromarray(out.astype(np.uint8), "RGB")


def radial(center, radius, stops):
    ys, xs = np.mgrid[0:W, 0:W].astype(np.float32)
    t = np.sqrt((xs - P(center[0])) ** 2 + (ys - P(center[1])) ** 2) / P(radius)
    t = np.clip(t, 0, 1)
    ts = np.array([s[0] for s in stops], dtype=np.float32)
    cols = np.array([hexrgb(s[1]) for s in stops], dtype=np.float32)
    out = np.zeros((W, W, 3), dtype=np.float32)
    for c in range(3):
        out[..., c] = np.interp(t, ts, cols[:, c])
    return Image.fromarray(out.astype(np.uint8), "RGB")


def paint(canvas, mask, fill, alpha=255):
    """Puts a colour ("#rrggbb") or an RGB image onto the canvas where the mask is."""
    if isinstance(fill, str):
        fill = Image.new("RGB", (W, W), hexrgb(fill))
    m = mask if alpha == 255 else mask.point(lambda p: p * alpha // 255)
    layer = fill.convert("RGBA")
    layer.putalpha(m)
    canvas.alpha_composite(layer)


def shadow(canvas, mask, dx, dy, blur, alpha):
    m = shift(mask, dx, dy).filter(ImageFilter.GaussianBlur(P(blur))).point(lambda p: p * alpha // 255)
    layer = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    layer.putalpha(m)
    canvas.alpha_composite(layer)


# ---------------------------------------------------------------------------------------------------------------
# the gear
# ---------------------------------------------------------------------------------------------------------------
def gear_mask(cx, cy, outer, root, hole, teeth, top, base, turn, round_):
    """teeth: how many; top / base: half width of a tooth at its top and at its foot, as a part of the pitch."""
    pitch = 2 * math.pi / teeth
    pts = []
    for i in range(teeth):
        c = turn + i * pitch
        for frac, r in ((-base, root), (-top, outer), (top, outer), (base, root)):
            a = c + frac * pitch
            pts.append((cx + r * math.cos(a), cy + r * math.sin(a)))
        # along the root circle to the next tooth
        for k in range(1, 6):
            a = c + (base + (1 - 2 * base) * k / 6) * pitch
            pts.append((cx + root * math.cos(a), cy + root * math.sin(a)))
    m = rounded(poly_mask(pts), round_)
    d = ImageDraw.Draw(m)
    circle(d, cx, cy, hole, 0)
    return m


def draw_gear(canvas, o):
    cx, cy = o["gear_center"]
    m = gear_mask(cx, cy, o["outer"], o["root"], o["hole"], o["teeth"], o["tooth_top"], o["tooth_base"], o["turn"], o["round"])
    if o["shadow"]:
        shadow(canvas, m, o["shadow"][0], o["shadow"][1], o["shadow"][2], o["shadow"][3])
    line = o["line"]
    inner = erode(m, line)
    # outline: a darker steel blue, a little lighter at the upper left
    paint(canvas, m, gradient((cx - o["outer"], cy - o["outer"]), (cx + o["outer"], cy + o["outer"]),
                              [(0, "#5C7299"), (1, "#2C3D5E")]))
    # the face: polished steel, light from the upper left
    paint(canvas, inner, gradient((cx - o["outer"] * 0.8, cy - o["outer"] * 0.8), (cx + o["outer"] * 0.8, cy + o["outer"] * 0.8),
                                  [(0, "#FFFFFF"), (0.28, "#E1E9F6"), (0.62, "#AFC0DB"), (1, "#7287AE")]))
    if o["bevel"]:
        b = o["bevel"]
        paint(canvas, minus(inner, shift(inner, b, b)), "#FFFFFF", 200)             # lit edges
        paint(canvas, minus(inner, shift(inner, -b, -b)), "#3D5078", 120)           # edges in the shade
    if o["hub"]:
        # a raised ring around the hole
        ring = new_mask()
        d = ImageDraw.Draw(ring)
        circle(d, cx, cy, o["hub"], 255)
        circle(d, cx, cy, o["hole"] + line, 0)
        ring = both(ring, inner)
        edge = minus(ring, erode(ring, o["hub_line"]))
        paint(canvas, ring, gradient((cx - o["hub"], cy - o["hub"]), (cx + o["hub"], cy + o["hub"]),
                                     [(0, "#F7FAFF"), (0.5, "#CBD7EA"), (1, "#93A6C6")]))
        paint(canvas, edge, gradient((cx - o["hub"], cy - o["hub"]), (cx + o["hub"], cy + o["hub"]),
                                     [(0, "#8296B8"), (1, "#56698E")]), 230)
        if o["bevel"]:
            b = o["bevel"]
            core = erode(ring, o["hub_line"])
            paint(canvas, minus(core, shift(core, b, b)), "#FFFFFF", 190)
    if o["gloss"]:
        # the soft shine of XP icons: a light veil over the upper left part of the face
        g = new_mask()
        d = ImageDraw.Draw(g)
        r = o["outer"] * 1.05
        d.ellipse([P(cx - r * 1.25), P(cy - r * 1.55), P(cx + r * 0.75), P(cy + r * 0.10)], fill=255)
        g = both(g.filter(ImageFilter.GaussianBlur(P(6))), inner)
        paint(canvas, g, "#FFFFFF", o["gloss"])
    return m


# ---------------------------------------------------------------------------------------------------------------
# the ore crystals
# ---------------------------------------------------------------------------------------------------------------
def crystal_faces(base, angle, width, body, tip, edge):
    """One crystal: a six-sided column seen from the front. base: where its foot stands (units); angle: lean in
    degrees (0 = upright, positive = to the right); width; body: height of the column; tip: height of the point;
    edge: where the front edge runs, -0.5 .. 0.5 of the width. Returns {name: points}."""
    a = math.radians(angle)
    ca, sa = math.cos(a), math.sin(a)

    def at(x, y):       # local: x to the right, y up along the crystal
        return (base[0] + x * ca + y * sa, base[1] + x * sa - y * ca)

    h = width / 2
    e = edge * width
    left = [at(-h, 0), at(e, -width * 0.10), at(e, body + width * 0.10), at(-h, body - width * 0.05)]
    right = [at(e, -width * 0.10), at(h, 0), at(h, body - width * 0.22), at(e, body + width * 0.10)]
    apex = at(e * 0.4, body + tip)
    tip_left = [at(-h, body - width * 0.05), at(e, body + width * 0.10), apex]
    tip_right = [at(e, body + width * 0.10), at(h, body - width * 0.22), apex]
    return {"left": left, "right": right, "tip_left": tip_left, "tip_right": tip_right,
            "axis": (at(e, -width * 0.10), at(e, body + width * 0.10), apex),
            "span": (at(0, 0), at(0, body + tip))}


FACE_COLOURS = {
    # (colour at the foot, colour at the top)
    "left": ("#2F8BEA", "#9AD6FF"),
    "right": ("#0C3F9E", "#2A78DC"),
    "tip_left": ("#BEE8FF", "#F2FBFF"),
    "tip_right": ("#3F97F0", "#8CCBFF"),
}


def draw_crystals(canvas, o):
    crystals = [crystal_faces(*c) for c in o["crystals"]]
    whole = new_mask()
    d = ImageDraw.Draw(whole)
    for c in crystals:
        for name in ("left", "right", "tip_left", "tip_right"):
            d.polygon([(P(x), P(y)) for x, y in c[name]], fill=255)
    whole = rounded(whole, o["crystal_round"])
    line = o["crystal_line"]
    if o["glow"]:
        g = whole.filter(ImageFilter.GaussianBlur(P(o["glow"][0]))).point(lambda p: min(255, p * o["glow"][1] // 255))
        layer = Image.new("RGBA", (W, W), hexrgb("#7CCBFF") + (0,))
        layer.putalpha(g)
        canvas.alpha_composite(layer)
    if o["shadow"]:
        shadow(canvas, whole, o["shadow"][0], o["shadow"][1], o["shadow"][2], o["shadow"][3])
    for c in crystals:      # from the back to the front
        one = new_mask()
        d = ImageDraw.Draw(one)
        for name in ("left", "right", "tip_left", "tip_right"):
            d.polygon([(P(x), P(y)) for x, y in c[name]], fill=255)
        one = both(rounded(one, o["crystal_round"]), whole)
        paint(canvas, one, "#0A2E78")                   # outline colour; the faces go on top, inside it
        inner = erode(one, line)
        foot, top = c["span"]
        for name in ("left", "right", "tip_left", "tip_right"):
            face = both(poly_mask(c[name]), inner)
            lo, hi = FACE_COLOURS[name]
            paint(canvas, face, gradient(foot, top, [(0, lo), (1, hi)]))
        if o["crystal_edges"]:
            # the front edge and the edges of the point catch the light
            e = new_mask()
            d = ImageDraw.Draw(e)
            a0, a1, apex = c["axis"]
            w_ = int(P(o["crystal_edges"]))
            d.line([(P(a0[0]), P(a0[1])), (P(a1[0]), P(a1[1]))], fill=255, width=w_)
            d.line([(P(a1[0]), P(a1[1])), (P(apex[0]), P(apex[1]))], fill=255, width=w_)
            d.line([(P(c["tip_left"][0][0]), P(c["tip_left"][0][1])), (P(a1[0]), P(a1[1]))], fill=255, width=w_)
            d.line([(P(c["tip_right"][1][0]), P(c["tip_right"][1][1])), (P(a1[0]), P(a1[1]))], fill=255, width=w_)
            paint(canvas, both(e, inner), "#FFFFFF", 150)
        if o["crystal_shine"]:
            # a streak of light on the left face
            s = new_mask()
            d = ImageDraw.Draw(s)
            l = c["left"]
            p0 = (l[0][0] * 0.62 + l[1][0] * 0.38, l[0][1] * 0.62 + l[1][1] * 0.38)
            p1 = (l[3][0] * 0.62 + l[2][0] * 0.38, l[3][1] * 0.62 + l[2][1] * 0.38)
            p0 = (p0[0] * 0.75 + p1[0] * 0.25, p0[1] * 0.75 + p1[1] * 0.25)
            d.line([(P(p0[0]), P(p0[1])), (P(p1[0]), P(p1[1]))], fill=255, width=int(P(o["crystal_shine"])))
            s = both(s.filter(ImageFilter.GaussianBlur(P(1.2))), inner)
            paint(canvas, s, "#FFFFFF", 120)
    return whole


# ---------------------------------------------------------------------------------------------------------------
# the sizes
# ---------------------------------------------------------------------------------------------------------------
def options(size):
    big = {
        "gear_center": (108, 108), "outer": 100, "root": 76, "hole": 27, "teeth": 8, "tooth_top": 0.160, "tooth_base": 0.250,
        "turn": math.radians(22.5), "round": 3.0, "line": 3.2, "bevel": 2.2, "hub": 50, "hub_line": 2.6, "gloss": 95,
        "shadow": (4, 6, 5, 95),
        # back to front: (foot, lean, width, body, point, front edge)
        "crystals": [((164, 232), -27, 34, 60, 26, -0.06),
                     ((210, 234), 31, 28, 42, 20, 0.10),
                     ((186, 236), 5, 46, 90, 40, -0.08),
                     ((168, 238), -40, 24, 16, 16, -0.05),
                     ((205, 239), 46, 22, 12, 14, 0.06)],
        "crystal_line": 3.0, "crystal_round": 1.2, "crystal_edges": 1.6, "crystal_shine": 5.0, "glow": (7, 90),
    }
    o = dict(big)
    if size <= 16:
        o.update({"gear_center": (112, 112), "outer": 112, "root": 80, "hole": 23, "tooth_top": 0.170, "tooth_base": 0.26,
                  "turn": 0.0, "round": 1.5, "line": 14, "bevel": 0, "hub": 0, "gloss": 50, "shadow": None,
                  "crystals": [((194, 240), 6, 74, 76, 54, -0.08)],
                  "crystal_line": 13, "crystal_round": 0.8, "crystal_edges": 0, "crystal_shine": 0, "glow": None})
    elif size <= 24:
        o.update({"gear_center": (112, 112), "outer": 108, "root": 81, "hole": 25, "tooth_top": 0.205, "tooth_base": 0.275,
                  "turn": 0.0, "round": 1.5, "line": 9.5, "bevel": 0, "hub": 0, "gloss": 60, "shadow": None,
                  "crystals": [((166, 236), -27, 44, 46, 30, -0.06), ((196, 240), 6, 60, 82, 46, -0.08)],
                  "crystal_line": 9.5, "crystal_round": 1.0, "crystal_edges": 0, "crystal_shine": 0, "glow": None})
    elif size <= 32:
        o.update({"line": 7.2, "bevel": 3.6, "hub": 52, "hub_line": 6.0, "gloss": 80, "shadow": (5, 7, 5, 90), "round": 2.4,
                  "crystals": [((162, 232), -27, 38, 56, 28, -0.06), ((212, 234), 31, 32, 38, 22, 0.10),
                               ((186, 238), 5, 52, 88, 42, -0.08)],
                  "crystal_line": 7.0, "crystal_edges": 0, "crystal_shine": 7.0, "glow": (7, 80)})
    elif size <= 48:
        o.update({"line": 5.0, "bevel": 2.8, "hub_line": 4.2, "crystal_line": 4.8, "crystal_edges": 2.4, "crystal_shine": 6.0,
                  "crystals": big["crystals"][:3]})
    elif size <= 64:
        o.update({"line": 4.0, "bevel": 2.4, "hub_line": 3.4, "crystal_line": 3.8, "crystal_edges": 2.0})
    return o


def render(size):
    canvas = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    o = options(size)
    draw_gear(canvas, o)
    draw_crystals(canvas, o)
    out = canvas.resize((size, size), Image.LANCZOS)
    if size <= 48:
        out = out.filter(ImageFilter.UnsharpMask(radius=0.6, percent=70 if size > 24 else 45, threshold=0))
    return out


# ---------------------------------------------------------------------------------------------------------------
# the .ico file: 256 as PNG, the others as 32-bit bitmaps (what Windows XP and everything later reads)
# ---------------------------------------------------------------------------------------------------------------
def bmp_entry(img):
    w, h = img.size
    px = np.array(img.convert("RGBA"))
    bgra = px[::-1, :, [2, 1, 0, 3]].tobytes()                 # bottom-up, BGRA
    row = ((w + 31) // 32) * 4
    mask = bytearray()
    alpha = px[::-1, :, 3]
    for y in range(h):
        bits = bytearray(row)
        for x in range(w):
            if alpha[y, x] == 0:
                bits[x // 8] |= 0x80 >> (x % 8)
        mask += bits
    header = struct.pack("<IiiHHIIiiII", 40, w, h * 2, 1, 32, 0, len(bgra) + len(mask), 0, 0, 0, 0)
    return header + bgra + bytes(mask)


def png_entry(img):
    b = io.BytesIO()
    img.save(b, "PNG", optimize=True)
    return b.getvalue()


def write_ico(path, images):
    entries = []
    for img in images:
        s = img.size[0]
        data = png_entry(img) if s >= 256 else bmp_entry(img)
        entries.append((s, data))
    out = struct.pack("<HHH", 0, 1, len(entries))
    offset = 6 + 16 * len(entries)
    for s, data in entries:
        out += struct.pack("<BBBBHHII", s % 256, s % 256, 0, 0, 1, 32, len(data), offset)
        offset += len(data)
    for _, data in entries:
        out += data
    with open(path, "wb") as f:
        f.write(out)


SIZES = [256, 128, 64, 48, 32, 24, 16]


def sheet(images, path):
    """All sizes side by side on three backgrounds, and the small ones enlarged, for looking at."""
    backgrounds = ["#FFFFFF", "#ECE9D8", "#3A6EA5"]
    width = sum(s for s in SIZES) + 20 * (len(SIZES) + 1)
    row_h = 256 + 40
    zoom = [(16, 10), (24, 8), (32, 6), (48, 4)]
    zoom_w = sum(s * z for s, z in zoom) + 20 * (len(zoom) + 1)
    total_w = max(width, zoom_w)
    img = Image.new("RGB", (total_w, row_h * len(backgrounds) + 48 * 4 + 40 + 20), "#808080")
    y = 0
    for bg in backgrounds:
        band = Image.new("RGB", (total_w, row_h), hexrgb(bg))
        x = 20
        for s, im in zip(SIZES, images):
            band.paste(im, (x, 20 + (256 - s)), im)
            x += s + 20
        img.paste(band, (0, y))
        y += row_h
    band = Image.new("RGB", (total_w, 48 * 4 + 40 + 20), hexrgb("#ECE9D8"))
    x = 20
    by = {im.size[0]: im for im in images}
    for s, z in zoom:
        big = by[s].resize((s * z, s * z), Image.NEAREST)
        band.paste(big, (x, 20), big)
        x += s * z + 20
    img.paste(band, (0, y))
    img.save(path)


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else "."
    os.makedirs(out, exist_ok=True)
    images = [render(s) for s in SIZES]
    for s, im in zip(SIZES, images):
        im.save(os.path.join(out, "megamod-%d.png" % s))
    write_ico(os.path.join(out, "megamod.ico"), images)
    sheet(images, os.path.join(out, "sheet.png"))
    print("written:", os.path.join(out, "megamod.ico"), os.path.getsize(os.path.join(out, "megamod.ico")), "bytes")


if __name__ == "__main__":
    main()
