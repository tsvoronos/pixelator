#!/usr/bin/env python3
"""Renders assets/Pixelator.icns (and the Quick Action menu PNG).

The icon is the app's own effect: one smooth gradient panel whose right
half is averaged into hard-edged blocks, exactly like `redact()` does.
Requires Pillow — only needed to regenerate art, not to install.
"""
from PIL import Image, ImageDraw
import os, subprocess, shutil

S = 1024
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "assets")


def lerp(a, b, t):
    return tuple(round(a[i] + (b[i] - a[i]) * t) for i in range(3))


def rounded_mask(size, radius, ss=4):
    m = Image.new("L", (size * ss, size * ss), 0)
    ImageDraw.Draw(m).rounded_rectangle(
        [0, 0, size * ss - 1, size * ss - 1], radius=radius * ss, fill=255)
    return m.resize((size, size), Image.LANCZOS)


def vgrad(w, h, top, bot):
    strip = Image.new("RGB", (1, h))
    for y in range(h):
        strip.putpixel((0, y), lerp(top, bot, y / max(1, h - 1)))
    return strip.resize((w, h), Image.BICUBIC)


def panel_gradient(w, h):
    """A 'document': warm-to-cool gradient with dark text rows over it.

    The rows matter — they give the pixelation high-contrast structure to
    bite into, so the blocky half reads as redacted rather than blurry.
    """
    warm, mid, cool = (255, 206, 128), (233, 104, 120), (92, 128, 216)
    img = Image.new("RGB", (w, h))
    px = img.load()
    for y in range(h):
        for x in range(w):
            t = (x / (w - 1) * 0.6) + (y / (h - 1) * 0.4)
            px[x, y] = lerp(warm, mid, t / 0.5) if t < 0.5 else lerp(mid, cool, (t - 0.5) / 0.5)

    d = ImageDraw.Draw(img)
    ink = (26, 33, 43)
    rows = [(0.10, 0.78), (0.30, 0.92), (0.50, 0.62), (0.70, 0.86)]
    bar_h = h * 0.105
    for top_frac, width_frac in rows:
        y0 = h * top_frac
        d.rounded_rectangle([w * 0.075, y0, w * 0.075 + (w * 0.85) * width_frac, y0 + bar_h],
                            radius=bar_h * 0.35, fill=ink)
    return img


def pixelate_right(img, split_frac=0.46, cols=4):
    """Average the right portion into hard-edged blocks, like the app does."""
    w, h = img.size
    x0 = int(w * split_frac)
    block = max(1, (w - x0) // cols)
    px = img.load()
    for by in range(0, h, block):
        for bx in range(x0, w, block):
            x1, y1 = min(bx + block, w), min(by + block, h)
            n = (x1 - bx) * (y1 - by)
            r = g = b = 0
            for yy in range(by, y1):
                for xx in range(bx, x1):
                    c = px[xx, yy]
                    r += c[0]; g += c[1]; b += c[2]
            avg = (r // n, g // n, b // n)
            for yy in range(by, y1):
                for xx in range(bx, x1):
                    px[xx, yy] = avg
    return img


def build():
    # slate body
    body = vgrad(S, S, (74, 92, 112), (28, 37, 48))
    icon = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    icon.paste(body, (0, 0), rounded_mask(S, int(S * 0.225)))

    # inset panel carrying the demo gradient
    pad = int(S * 0.175)
    pw = ph = S - pad * 2
    panel = pixelate_right(panel_gradient(pw, ph))
    pmask = rounded_mask(pw, int(pw * 0.10))
    icon.paste(panel, (pad, pad), pmask)

    os.makedirs(OUT, exist_ok=True)
    icon.save(os.path.join(OUT, "icon-1024.png"))
    icon.resize((512, 512), Image.LANCZOS).save(os.path.join(OUT, "quickaction-icon.png"))

    # .icns via iconutil
    iconset = os.path.join(OUT, "Pixelator.iconset")
    shutil.rmtree(iconset, ignore_errors=True)
    os.makedirs(iconset)
    for sz in (16, 32, 128, 256, 512):
        icon.resize((sz, sz), Image.LANCZOS).save(f"{iconset}/icon_{sz}x{sz}.png")
        icon.resize((sz * 2, sz * 2), Image.LANCZOS).save(f"{iconset}/icon_{sz}x{sz}@2x.png")
    subprocess.run(["iconutil", "-c", "icns", iconset,
                    "-o", os.path.join(OUT, "Pixelator.icns")], check=True)
    shutil.rmtree(iconset)
    print("wrote assets/Pixelator.icns, assets/icon-1024.png, assets/quickaction-icon.png")


if __name__ == "__main__":
    build()
