# Paints the eyes out of assets/slo.png so the film can draw them as moving shapes.
# Run from promo/ after make_assets.py:  python scripts/make_eyes.py
# Output: assets/slo-noeyes.png. The eye shapes themselves are the <svg id="slo-eyes"> in compositions/film.html.
from PIL import Image
import numpy as np

im = Image.open("assets/slo.png").convert("RGBA")
a = np.array(im).astype(float)

# boxes around each eye in the 777x607 image: x0, x1, y0, y1
for x0, x1, y0, y1 in [(298, 444, 198, 276), (486, 624, 197, 273)]:
    for y in range(y0, y1):
        left = a[y, x0 - 4:x0, :3].mean(axis=0)
        right = a[y, x1:x1 + 4, :3].mean(axis=0)
        t = np.linspace(0, 1, x1 - x0)[:, None]
        a[y, x0:x1, :3] = left * (1 - t) + right * t   # blend across the gap, row by row
        a[y, x0:x1, 3] = 255

Image.fromarray(a.round().astype("uint8")).save("assets/slo-noeyes.png")
print("wrote assets/slo-noeyes.png")
