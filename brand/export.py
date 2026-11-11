"""Export the app icon from one direction SVG.

Usage:  python brand/export.py brand/directions/fable-2.svg

Writes into brand/:
  icon.svg, icon-foreground.svg, icon-background.svg
  icon-1024.png, icon-512.png, icon-192.png, icon-48.png
  android/res/...   (copy this tree over app/android/app/src/main/res/)

The direction SVG must be viewBox 0 0 1024 1024 with a full-bleed background
<rect> as its first element. Rendering uses headless Edge, then Pillow to downscale.
"""
import os, re, subprocess, sys, tempfile
from PIL import Image

EDGE = r"C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe"
HERE = os.path.dirname(os.path.abspath(__file__))
HEAD = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024">'


def render(svg_text, transparent=False):
    """Render SVG text to a 1024px RGBA image."""
    with tempfile.TemporaryDirectory() as tmp:
        src, out = os.path.join(tmp, "i.html"), os.path.join(tmp, "o.png")
        page = ('<!doctype html><meta charset="utf-8"><style>html,body{margin:0;background:transparent}'
                'svg{display:block;width:1024px;height:1024px}</style>' + svg_text)
        open(src, "w", encoding="utf-8").write(page)
        cmd = [EDGE, "--headless", "--disable-gpu", "--hide-scrollbars", "--force-device-scale-factor=1",
               "--window-size=1024,1024", f"--screenshot={out}"]
        if transparent:
            cmd.append("--default-background-color=00000000")
        subprocess.run(cmd + ["file:///" + src.replace("\\", "/")], timeout=60, capture_output=True, check=True)
        return Image.open(out).convert("RGBA").copy()


def save(img, path, size):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    img.resize((size, size), Image.LANCZOS).save(path)


def main(src):
    text = open(src, encoding="utf-8").read()
    inner = re.search(r"<svg[^>]*>(.*)</svg>", text, re.S).group(1).strip()
    m = re.match(r'<rect\b[^>]*?fill="(#[0-9a-fA-F]{3,8})"[^>]*?/>', inner)
    if not m:
        sys.exit("first element must be the background <rect ... fill=\"#hex\"/>")
    bg, glyph = m.group(1), inner[m.end():]
    bg_rect = f'<rect width="1024" height="1024" fill="{bg}"/>'

    master = f"{HEAD}{bg_rect}{glyph}</svg>"
    # Adaptive icons show the centre 72 of 108dp, so shrink the glyph by 2/3 to look the same once masked.
    fg = f'{HEAD}<g transform="translate(512 512) scale(0.6667) translate(-512 -512)">{glyph}</g></svg>'
    back = f"{HEAD}{bg_rect}</svg>"
    for name, body in (("icon.svg", master), ("icon-foreground.svg", fg), ("icon-background.svg", back)):
        open(os.path.join(HERE, name), "w", encoding="utf-8").write(body)

    full = render(master)
    for s in (1024, 512, 192, 48):
        save(full, os.path.join(HERE, f"icon-{s}.png"), s)

    res = os.path.join(HERE, "android", "res")
    fg_img = render(fg, transparent=True)
    for dpi, legacy, adaptive in (("mdpi", 48, 108), ("hdpi", 72, 162), ("xhdpi", 96, 216),
                                  ("xxhdpi", 144, 324), ("xxxhdpi", 192, 432)):
        save(full, os.path.join(res, f"mipmap-{dpi}", "ic_launcher.png"), legacy)
        save(fg_img, os.path.join(res, f"mipmap-{dpi}", "ic_launcher_foreground.png"), adaptive)
    os.makedirs(os.path.join(res, "mipmap-anydpi-v26"), exist_ok=True)
    os.makedirs(os.path.join(res, "values"), exist_ok=True)
    open(os.path.join(res, "mipmap-anydpi-v26", "ic_launcher.xml"), "w", encoding="utf-8").write(
        '<?xml version="1.0" encoding="utf-8"?>\n'
        '<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">\n'
        '    <background android:drawable="@color/ic_launcher_background"/>\n'
        '    <foreground android:drawable="@mipmap/ic_launcher_foreground"/>\n'
        '</adaptive-icon>\n')
    open(os.path.join(res, "values", "ic_launcher_background.xml"), "w", encoding="utf-8").write(
        '<?xml version="1.0" encoding="utf-8"?>\n<resources>\n'
        f'    <color name="ic_launcher_background">{bg}</color>\n</resources>\n')
    print("exported from", src, "background", bg)


if __name__ == "__main__":
    main(sys.argv[1])
