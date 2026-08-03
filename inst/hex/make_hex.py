"""
Compose the `commons` artwork into Posit-style hex stickers.

Usage (from anywhere; paths resolve relative to this file):

    python3 inst/hex/make_hex.py

Writes the variants into inst/hex/output/ (gitignored scratch space) and copies
the chosen one to inst/hex/commons.png, which is tracked.

Geometry is taken from rstudio/hex-stickers (broom.svg):
  canvas      2521 x 2911  (pointy-top regular hexagon, bleeds to canvas edge)
  outer hex   apothem 1260.5  (= 2521/2), height 2911
  inner hex   apothem 1198.4  -> border thickness 62.1 px, measured perpendicular
  border      a darker shade of the dominant fill colour
  gloss       optional white linear gradient, ~25% opacity, fading downward

Requires pillow.
"""

import math
import shutil
from pathlib import Path

from PIL import Image, ImageDraw

HERE = Path(__file__).resolve().parent
SRC = HERE / "commons-bg.png"   # source illustration (4096 x 4096)
OUT = HERE / "output"           # gitignored; scratch space for the riffs

# The variant we settled on. Copied up to inst/hex/commons.png, which sits
# outside the gitignored output/ dir so it can be tracked.
CHOSEN = "02-mid-teal"
FINAL = HERE / "commons.png"

W, H = 2521, 2911
OUTER_APOTHEM = W / 2.0          # 1260.5
BORDER = 62.1                    # perpendicular thickness, from broom.svg
SS = 3                           # supersample factor for clean edges


def hexagon(cx, cy, apothem):
    """Pointy-top regular hexagon vertices for a given apothem (half-width)."""
    R = apothem * 2.0 / math.sqrt(3.0)      # circumradius
    return [
        (cx, cy - R),
        (cx + apothem, cy - R / 2.0),
        (cx + apothem, cy + R / 2.0),
        (cx, cy + R),
        (cx - apothem, cy + R / 2.0),
        (cx - apothem, cy - R / 2.0),
    ]


def hex_mask(size, apothem, ss=SS):
    """Antialiased hexagon mask by drawing supersampled then downscaling."""
    w, h = size
    big = Image.new("L", (w * ss, h * ss), 0)
    ImageDraw.Draw(big).polygon(
        hexagon(w * ss / 2.0, h * ss / 2.0, apothem * ss), fill=255
    )
    return big.resize((w, h), Image.LANCZOS)


def crop_to_hex_aspect(img, zoom, focus_x, focus_y):
    """
    Crop a hex-aspect (0.866:1) window out of the square source.
    zoom=1.0 -> tallest window that fits (full height); larger zoom -> tighter.
    focus_* are fractions of the source that should land in the window centre.
    """
    sw, sh = img.size
    ch = sh / zoom
    cw = ch * math.sqrt(3.0) / 2.0
    if cw > sw:                     # never wider than the source
        cw = sw
        ch = cw * 2.0 / math.sqrt(3.0)
    cx, cy = focus_x * sw, focus_y * sh
    left = min(max(cx - cw / 2.0, 0), sw - cw)
    top = min(max(cy - ch / 2.0, 0), sh - ch)
    box = (round(left), round(top), round(left + cw), round(top + ch))
    return img.crop(box).resize((W, H), Image.LANCZOS)


def add_gloss(base, strength=0.25):
    """broom-style white gradient down from the top vertex."""
    grad = Image.new("L", (1, H))
    for y in range(H):
        t = y / (H - 1)
        if t < 0.56:
            a = 0.83 + (0.37 - 0.83) * (t / 0.56)
        else:
            a = 0.37 * (1 - (t - 0.56) / 0.44)
        grad.putpixel((0, y), int(max(a, 0) * 255 * strength))
    alpha = grad.resize((W, H))
    white = Image.new("RGBA", (W, H), (255, 255, 255, 255))
    white.putalpha(alpha)
    return Image.alpha_composite(base, white)


def make(name, zoom, focus, border_rgb, border_px=BORDER,
         inner_line=None, inner_line_px=14, gloss=0.0):
    src = Image.open(SRC).convert("RGB")
    art = crop_to_hex_aspect(src, zoom, *focus).convert("RGBA")

    canvas = Image.new("RGBA", (W, H), (0, 0, 0, 0))

    # outer hexagon = border colour, bleeding to the canvas edge
    border_layer = Image.new("RGBA", (W, H), tuple(border_rgb) + (255,))
    canvas.paste(border_layer, (0, 0), hex_mask((W, H), OUTER_APOTHEM))

    # optional thin accent line between border and artwork
    if inner_line is not None:
        line_layer = Image.new("RGBA", (W, H), tuple(inner_line) + (255,))
        canvas.paste(line_layer, (0, 0),
                     hex_mask((W, H), OUTER_APOTHEM - border_px))
        art_apothem = OUTER_APOTHEM - border_px - inner_line_px
    else:
        art_apothem = OUTER_APOTHEM - border_px

    canvas.paste(art, (0, 0), hex_mask((W, H), art_apothem))

    if gloss:
        inner = hex_mask((W, H), art_apothem)
        canvas = Image.composite(add_gloss(canvas, gloss), canvas, inner)

    OUT.mkdir(parents=True, exist_ok=True)
    path = OUT / f"commons-hex-{name}.png"
    canvas.save(path)
    print(f"{path.name}  {canvas.size[0]}x{canvas.size[1]}  {canvas.mode}")
    return path


BROWN_DARK = (110, 66, 40)     # deep fence shadow
BROWN_MID = (146, 86, 60)      # fence body
TEAL_DARK = (42, 92, 97)       # kingfisher wing, darkened
GREEN_DARK = (94, 106, 58)     # meadow / tree canopy, darkened
CREAM = (250, 243, 226)

if __name__ == "__main__":
    # zoom is capped around 1.3: past that the beak/crown run into the upper
    # taper of the hexagon and the nameplate crowds the vertical sides.
    WIDE = (1.0, (0.51, 0.50))
    MID = (1.15, (0.508, 0.50))
    CLOSE = (1.3, (0.505, 0.50))

    written = {}

    # 1. full scene, classic single dark-brown border
    written["01-wide-brown"] = make("01-wide-brown", *WIDE, BROWN_DARK)

    # 2. medium crop, teal border pulled from the kingfisher  <- chosen
    written["02-mid-teal"] = make("02-mid-teal", *MID, TEAL_DARK)

    # 3. close crop, brown border + cream keyline
    written["03-tight-keyline"] = make("03-tight-keyline", *CLOSE, BROWN_DARK,
                                      inner_line=CREAM, inner_line_px=18)

    # 4. full scene, thin meadow-green border
    written["04-wide-green-thin"] = make("04-wide-green-thin", *WIDE,
                                        GREEN_DARK, border_px=40)

    # 5. medium crop, fence-brown border + broom-style gloss sheen
    written["05-mid-gloss"] = make("05-mid-gloss", *MID, BROWN_MID, gloss=0.22)

    # 6. close crop, chunky teal border
    written["06-tight-teal-thick"] = make("06-tight-teal-thick", *CLOSE,
                                         TEAL_DARK, border_px=95)

    shutil.copyfile(written[CHOSEN], FINAL)
    print(f"{FINAL.name}  <- output/{written[CHOSEN].name}")
