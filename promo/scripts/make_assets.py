"""Cut the ghost and its spinner out of brand/icon-1024.png as separate transparent layers.

Run from promo/:  python scripts/make_assets.py
Writes assets/slo.png (the ghost holding its phone, transparent ground).
"""
from collections import deque
from pathlib import Path

from PIL import Image, ImageFilter

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT.parent / "brand" / "icon-1024.png"
OUT = ROOT / "assets"
OUT.mkdir(exist_ok=True)

BG = (2, 3, 12)
TOLERANCE = 6  # the phone in the ghost's hands is about 12 away from the ground colour, so it stays

im = Image.open(SRC).convert("RGB")
w, h = im.size
px = im.load()


def is_ground(p):
    return all(abs(p[i] - BG[i]) <= TOLERANCE for i in range(3)) or sum(p) < 12  # also the black corners


mask = Image.new("L", (w, h), 255)
m = mask.load()
queue = deque()
for x in range(w):
    queue.append((x, 0))
    queue.append((x, h - 1))
for y in range(h):
    queue.append((0, y))
    queue.append((w - 1, y))
seen = set()
while queue:
    x, y = queue.popleft()
    if (x, y) in seen or not (0 <= x < w and 0 <= y < h):
        continue
    seen.add((x, y))
    if not is_ground(px[x, y]):
        continue
    m[x, y] = 0
    queue.extend(((x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)))

# keep only the piece connected to the ghost's body, so the loading bars (drawn as SVG in the film) drop out
keep = Image.new("L", (w, h), 0)
k = keep.load()
queue = deque([(300, 520)])
seen = set()
while queue:
    x, y = queue.popleft()
    if (x, y) in seen or not (0 <= x < w and 0 <= y < h):
        continue
    seen.add((x, y))
    if m[x, y] == 0:
        continue
    k[x, y] = 255
    queue.extend(((x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)))

keep = keep.filter(ImageFilter.MinFilter(5)).filter(ImageFilter.GaussianBlur(1.0))  # shave the dark fringe
ghost = im.convert("RGBA")
ghost.putalpha(keep)
box = ghost.getbbox()
ghost.crop(box).save(OUT / "slo.png")
print("slo box", box)
