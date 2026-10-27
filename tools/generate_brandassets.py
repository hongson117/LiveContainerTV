#!/usr/bin/env python3
"""Generate tvOS layered App Icon & Top Shelf brand assets for LiveContainerTV."""
import json, os
from PIL import Image, ImageDraw, ImageFont, ImageFilter

OUT = os.path.join(os.path.dirname(__file__), "..", "Host", "Assets.xcassets", "App Icon & Top Shelf Image.brandassets")
os.makedirs(OUT, exist_ok=True)

NAVY = (15, 23, 42)
GOLD = (212, 175, 55)
TEAL = (45, 212, 191)
WHITE = (255, 255, 255)

def font(size):
    for p in [
        "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
        "/usr/share/fonts/truetype/liberation/LiberationSans-Bold.ttf",
        "/usr/share/fonts/opentype/noto/NotoSans-Bold.ttf",
    ]:
        if os.path.exists(p):
            return ImageFont.truetype(p, size)
    return ImageFont.load_default()

def rounded_rect(draw, box, r, fill):
    draw.rounded_rectangle(box, radius=r, fill=fill)

def make_layers(w, h):
    # Back: navy with soft teal glow
    back = Image.new("RGB", (w, h), NAVY)
    d = ImageDraw.Draw(back)
    cx, cy = w // 2, h // 2
    for i, r in enumerate(range(min(w, h) // 2, 0, -max(8, min(w, h) // 40))):
        a = int(28 * (1 - r / (min(w, h) / 2)))
        d.ellipse([cx - r, cy - r, cx + r, cy + r], fill=(NAVY[0], NAVY[1] + a, NAVY[2] + a // 2))

    # Middle: container outline (rounded rect "box")
    mid = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    md = ImageDraw.Draw(mid)
    pad = int(min(w, h) * 0.12)
    box = [pad, pad + int(h * 0.05), w - pad, h - pad - int(h * 0.05)]
    r = int(min(w, h) * 0.12)
    # outer gold rim
    md.rounded_rectangle(box, radius=r, outline=GOLD + (230,), width=max(4, w // 80))
    # inner teal rim
    inset = max(6, w // 60)
    ib = [box[0] + inset, box[1] + inset, box[2] - inset, box[3] - inset]
    md.rounded_rectangle(ib, radius=max(4, r - inset), outline=TEAL + (180,), width=max(2, w // 120))
    # subtle fill
    fill = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    fd = ImageDraw.Draw(fill)
    fd.rounded_rectangle(ib, radius=max(4, r - inset), fill=(30, 41, 59, 160))
    mid = Image.alpha_composite(fill, mid)

    # Front: "LC TV" text
    front = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    fd = ImageDraw.Draw(front)
    f1 = font(max(28, h // 5))
    f2 = font(max(18, h // 8))
    t1, t2 = "LC", "TV"
    # measure
    b1 = fd.textbbox((0, 0), t1, font=f1)
    b2 = fd.textbbox((0, 0), t2, font=f2)
    tw1, th1 = b1[2] - b1[0], b1[3] - b1[1]
    tw2, th2 = b2[2] - b2[0], b2[3] - b2[1]
    gap = max(4, h // 40)
    total_h = th1 + gap + th2
    y0 = (h - total_h) // 2 - b1[1]
    fd.text(((w - tw1) // 2 - b1[0], y0), t1, font=f1, fill=WHITE + (255,))
    fd.text(((w - tw2) // 2 - b2[0], y0 + th1 + gap), t2, font=f2, fill=GOLD + (255,))
    return back, mid, front

def write_layerstack(name, w, h):
    stack = os.path.join(OUT, f"{name}.imagestack")
    os.makedirs(stack, exist_ok=True)
    back, mid, front = make_layers(w, h)
    layers = [("Back", back), ("Middle", mid), ("Front", front)]
    layer_refs = []
    for lname, img in layers:
        ldir = os.path.join(stack, f"{lname}.imagestacklayer")
        cdir = os.path.join(ldir, "Content.imageset")
        os.makedirs(cdir, exist_ok=True)
        fn = "Content.png"
        img.save(os.path.join(cdir, fn), "PNG")
        with open(os.path.join(cdir, "Contents.json"), "w") as f:
            json.dump({"images": [{"idiom": "tv", "filename": fn, "scale": "1x"},
                                  {"idiom": "tv", "scale": "2x"}],
                       "info": {"version": 1, "author": "xcode"}}, f, indent=2)
        with open(os.path.join(ldir, "Contents.json"), "w") as f:
            json.dump({"info": {"version": 1, "author": "xcode"}}, f, indent=2)
        layer_refs.append({"filename": f"{lname}.imagestacklayer"})
    with open(os.path.join(stack, "Contents.json"), "w") as f:
        json.dump({"layers": layer_refs, "info": {"version": 1, "author": "xcode"},
                   "properties": {"canvasSize": {"width": w, "height": h}}}, f, indent=2)
    return f"{name}.imagestack"

def write_topshelf(name, w, h):
    iset = os.path.join(OUT, f"{name}.imageset")
    os.makedirs(iset, exist_ok=True)
    img = Image.new("RGB", (w, h), NAVY)
    d = ImageDraw.Draw(img)
    # left accent bar
    d.rectangle([0, 0, w // 40, h], fill=GOLD)
    # big container motif on the right third
    cx = int(w * 0.78); cy = h // 2
    bw, bh = int(h * 0.7), int(h * 0.55)
    box = [cx - bw // 2, cy - bh // 2, cx + bw // 2, cy + bh // 2]
    d.rounded_rectangle(box, radius=h // 20, outline=GOLD, width=max(4, h // 60))
    d.rounded_rectangle([box[0] + 10, box[1] + 10, box[2] - 10, box[3] - 10],
                        radius=h // 24, outline=TEAL, width=max(2, h // 90))
    f = font(max(48, h // 6))
    text = "LiveContainer TV"
    bb = d.textbbox((0, 0), text, font=f)
    tw, th = bb[2] - bb[0], bb[3] - bb[1]
    d.text((int(w * 0.08), (h - th) // 2 - bb[1]), text, font=f, fill=WHITE)
    sub = font(max(22, h // 14))
    st = "Run apps inside one signed host"
    sb = d.textbbox((0, 0), st, font=sub)
    d.text((int(w * 0.08), (h - th) // 2 - bb[1] + th + 12), st, font=sub, fill=TEAL)
    fn = "shelf.png"
    img.save(os.path.join(iset, fn), "PNG")
    with open(os.path.join(iset, "Contents.json"), "w") as f:
        json.dump({"images": [{"idiom": "tv", "filename": fn, "scale": "1x"},
                              {"idiom": "tv", "scale": "2x"}],
                   "info": {"version": 1, "author": "xcode"}}, f, indent=2)
    return f"{name}.imageset"

# Small App Icon: 400x240
small = write_layerstack("App Icon - Small", 400, 240)
# Large App Icon: 1280x768
large = write_layerstack("App Icon - Large", 1280, 768)
# Top Shelf 1x 1920x720
ts1 = write_topshelf("Top Shelf Image", 1920, 720)
# Top Shelf wide 2320x720 (tvOS 13+)
tsw = write_topshelf("Top Shelf Image Wide", 2320, 720)

with open(os.path.join(OUT, "Contents.json"), "w") as f:
    json.dump({
        "assets": [
            {"idiom": "tv", "role": "primary-app-icon", "size": "1280x768", "filename": large},
            {"idiom": "tv", "role": "primary-app-icon", "size": "400x240", "filename": small},
            {"idiom": "tv", "role": "top-shelf-image", "size": "1920x720", "filename": ts1},
            {"idiom": "tv", "role": "top-shelf-image-wide", "size": "2320x720", "filename": tsw},
        ],
        "info": {"version": 1, "author": "xcode"}
    }, f, indent=2)

# Parent Assets.xcassets Contents
parent = os.path.join(os.path.dirname(OUT), "Contents.json")
with open(parent, "w") as f:
    json.dump({"info": {"version": 1, "author": "xcode"}}, f, indent=2)
print("Wrote brand assets to", OUT)
