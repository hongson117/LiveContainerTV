#!/usr/bin/env python3
"""Render the LiveContainerTV 3D logo as tvOS parallax layers + previews."""
import math, os, sys
from PIL import Image, ImageDraw, ImageFilter, ImageFont, ImageChops
SS = 3
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BA = os.path.join(ROOT, "Host/Assets.xcassets/App Icon & Top Shelf Image.brandassets")

def lerp(a, b, t): return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(len(a)))

def lin_grad(size, c0, c1, angle=90):
    w, h = size
    g = Image.new("RGBA", (256, 1))
    for x in range(256): g.putpixel((x, 0), lerp(c0, c1, x / 255))
    big = int(math.hypot(w, h)) + 2
    g = g.resize((big, big)).rotate(-angle + 90, resample=Image.BICUBIC)
    l = (big - w) // 2; t = (big - h) // 2
    return g.crop((l, t, l + w, t + h))

def radial(size, center, r, c_in, c_out):
    w, h = size
    m = Image.new("L", (512, 512))
    d = ImageDraw.Draw(m)
    for i in range(256, 0, -1):
        v = int(255 * (1 - i / 256) ** 1.6)
        d.ellipse((256 - i, 256 - i, 256 + i, 256 + i), fill=v)
    m = m.resize((int(2 * r), int(2 * r)), Image.BICUBIC)
    mask = Image.new("L", size, 0); mask.paste(m, (int(center[0] - r), int(center[1] - r)))
    base = Image.new("RGBA", size, c_out); top = Image.new("RGBA", size, c_in)
    return Image.composite(top, base, mask)

def fill_poly(img, pts, c0, c1, angle):
    mask = Image.new("L", img.size, 0); ImageDraw.Draw(mask).polygon(pts, fill=255)
    img.paste(lin_grad(img.size, c0, c1, angle), (0, 0), mask)

def geom(W, H, cx, cy, s):
    # isometric cube: s = edge length on screen
    dx, dy = s * math.cos(math.radians(30)), s * 0.5
    top = (cx, cy - s); 
    T = [(cx, cy - s - dy), (cx + dx, cy - s), (cx, cy - s + dy), (cx - dx, cy - s)]
    T = [(x, y + s * 0.5) for x, y in T]
    a, b, c, d = T  # back, right, front, left
    L = [d, c, (c[0], c[1] + s), (d[0], d[1] + s)]
    R = [c, b, (b[0], b[1] + s), (c[0], c[1] + s)]
    return T, L, R

def layers(W, H, cx=None, cy=None, scale=0.5):
    cx = W / 2 if cx is None else cx; cy = H / 2 if cy is None else cy
    W, H, cx, cy = W * SS, H * SS, cx * SS, cy * SS
    s = H * scale * 0.34
    # BACK
    back = lin_grad((W, H), (18, 16, 64, 255), (8, 40, 92, 255), 135)
    glow = radial((W, H), (cx, cy - s * 0.1), s * 1.9, (124, 58, 237, 255), (0, 0, 0, 0))
    back = Image.alpha_composite(back, Image.blend(Image.new("RGBA", (W, H), (0, 0, 0, 0)), glow, 0.55))
    glow2 = radial((W, H), (cx + s * 1.3, cy + s * 0.9), s * 1.4, (20, 184, 166, 255), (0, 0, 0, 0))
    back = Image.alpha_composite(back, Image.blend(Image.new("RGBA", (W, H), (0, 0, 0, 0)), glow2, 0.35))
    # MIDDLE: cube
    mid = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    T, L, R = geom(W, H, cx, cy - s * 0.05, s)
    sh = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    bx = (L[3][0], L[3][1]); ex = (R[2][0], R[2][1])
    ImageDraw.Draw(sh).ellipse((bx[0] - s * .1, ex[1] - s * .25, ex[0] + s * .1, ex[1] + s * .35), fill=(0, 0, 0, 150))
    mid = Image.alpha_composite(mid, sh.filter(ImageFilter.GaussianBlur(s * 0.12)))
    fill_poly(mid, T, (253, 230, 138, 255), (245, 158, 11, 255), 160)
    fill_poly(mid, L, (234, 88, 12, 255), (180, 50, 10, 255), 90)
    fill_poly(mid, R, (190, 60, 12, 255), (120, 30, 8, 255), 90)
    d = ImageDraw.Draw(mid)
    for poly in (T, L, R): d.line(poly + [poly[0]], fill=(255, 240, 200, 110), width=max(2, int(s * 0.012)))
    # container ribs on the right face
    for i in range(1, 6):
        t = i / 6
        p0 = lerp(R[0], R[1], t); p1 = lerp(R[3], R[2], t)
        d.line([p0, p1], fill=(90, 20, 5, 150), width=max(2, int(s * 0.018)))
    # TV screen on left face (inset parallelogram)
    def inset(face, m):
        a, b, c, dd = face
        def P(u, v): return (a[0] + (b[0] - a[0]) * u + (dd[0] - a[0]) * v, a[1] + (b[1] - a[1]) * u + (dd[1] - a[1]) * v)
        return [P(m, m), P(1 - m, m), P(1 - m, 1 - m), P(m, 1 - m)], P
    scr, P = inset(L, 0.14)
    fill_poly(mid, scr, (15, 23, 42, 255), (30, 64, 120, 255), 60)
    d.line(scr + [scr[0]], fill=(30, 10, 0, 220), width=max(3, int(s * 0.03)))
    # FRONT: play glyph on screen + gloss
    front = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    a, b, c = P(0.36, 0.30), P(0.36, 0.70), P(0.70, 0.55)
    a = (a[0], a[1]); tri = [a, b, c]
    gl = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    ImageDraw.Draw(gl).polygon(tri, fill=(45, 212, 191, 255))
    front = Image.alpha_composite(front, gl.filter(ImageFilter.GaussianBlur(s * 0.06)))
    fill_poly(front, tri, (167, 243, 208, 255), (20, 184, 166, 255), 120)
    # gloss streak across the top face
    gloss = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    gT = [lerp(T[3], T[0], .25), lerp(T[0], T[1], .35), lerp(T[1], T[2], .2), lerp(T[3], T[2], .55)]
    ImageDraw.Draw(gloss).polygon(gT, fill=(255, 255, 255, 90))
    front = Image.alpha_composite(front, gloss.filter(ImageFilter.GaussianBlur(s * 0.03)))
    # sparkle
    sp = Image.new("RGBA", (W, H), (0, 0, 0, 0)); ds = ImageDraw.Draw(sp)
    px, py = T[1][0] - s * .05, T[1][1] - s * .05; r = s * 0.16
    ds.polygon([(px, py - r), (px + r * .15, py), (px, py + r), (px - r * .15, py)], fill=(255, 255, 255, 230))
    ds.polygon([(px - r, py), (px, py + r * .15), (px + r, py), (px, py - r * .15)], fill=(255, 255, 255, 230))
    front = Image.alpha_composite(front, sp.filter(ImageFilter.GaussianBlur(1.5 * SS)))
    return back, mid, front

def down(img, W, H): return img.resize((W, H), Image.LANCZOS)

def font(sz):
    for f in ["/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf", "/usr/share/fonts/truetype/liberation/LiberationSans-Bold.ttf"]:
        if os.path.exists(f): return ImageFont.truetype(f, sz)
    return ImageFont.load_default()

def wordmark(img, x, y, sz):
    d = ImageDraw.Draw(img); f = font(sz); f2 = font(int(sz * 0.42))
    d.text((x + sz * 0.04, y + sz * 0.06), "LiveContainer", font=f, fill=(0, 0, 0, 140))
    d.text((x, y), "LiveContainer", font=f, fill=(255, 255, 255, 255))
    w = d.textlength("LiveContainer", font=f)
    d.rounded_rectangle((x + w + sz * .2, y + sz * .1, x + w + sz * 1.75, y + sz * 1.05), radius=sz * .2, fill=(245, 158, 11, 255))
    d.text((x + w + sz * .36, y + sz * .12), "TV", font=f, fill=(30, 15, 0, 255))
    d.text((x, y + sz * 1.3), "Run tvOS apps inside one sideloaded container", font=f2, fill=(203, 213, 225, 255))

def main():
    out_prev = os.path.join(ROOT, "dist/preview"); os.makedirs(out_prev, exist_ok=True)
    for name, (W, H) in {"Small": (400, 240), "Large": (1280, 768)}.items():
        b, m, f = layers(W, H, scale=1.0)
        stack = os.path.join(BA, f"App Icon - {name}.imagestack")
        for lname, im in (("Back", b), ("Middle", m), ("Front", f)):
            im = down(im, W, H)
            if lname == "Back": im = im.convert("RGB")
            im.save(os.path.join(stack, f"{lname}.imagestacklayer/Content.imageset/Content.png"))
        comp = Image.alpha_composite(Image.alpha_composite(b, m), f)
        down(comp, W, H).save(os.path.join(out_prev, f"icon_{name.lower()}.png"))
        if name == "Large":
            sq = comp.crop(((W * SS - H * SS) // 2, 0, (W * SS + H * SS) // 2, H * SS))
            sq = down(sq, 512, 512)
            mask = Image.new("L", (512 * 2, 512 * 2), 0); ImageDraw.Draw(mask).rounded_rectangle((0, 0, 1023, 1023), radius=220, fill=255)
            sq.putalpha(mask.resize((512, 512), Image.LANCZOS))
            os.makedirs(os.path.join(ROOT, "Host/Resources"), exist_ok=True)
            sq.save(os.path.join(ROOT, "Host/Resources/lctv_logo.png"))
            sq.save(os.path.join(out_prev, "logo_square.png"))
    for fname, (W, H) in {"Top Shelf Image.imageset/shelf.png": (1920, 720), "Top Shelf Image Wide.imageset/shelf.png": (2320, 720)}.items():
        b, m, f = layers(W, H, cx=W * 0.2, cy=H * 0.5, scale=1.0)
        comp = Image.alpha_composite(Image.alpha_composite(b, m), f)
        comp = down(comp, W, H)
        wordmark(comp, int(W * 0.40), int(H * 0.36), int(H * 0.13))
        comp.convert("RGB").save(os.path.join(BA, fname))
        comp.save(os.path.join(out_prev, "topshelf_wide.png" if "Wide" in fname else "topshelf.png"))
main()
