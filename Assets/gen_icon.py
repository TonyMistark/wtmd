"""Generate the wtmd app icon.

Visual concept (from docs/PRODUCT.md): "dashed line -> wtmd -> solid line".
Fleeting thoughts flow through the tool and settle into a composed document,
expressed as a single rule that starts dashed and resolves into a solid stroke.

Run:  python gen_icon.py            # writes 1024 preview + AppIcon.iconset
"""

from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path

from PIL import Image, ImageDraw

# --- geometry (all coordinates in a 1024x1024 design space) -----------------
CANVAS = 1024
SUPERSAMPLE = 4

# macOS icon grid: an 824pt rounded square centred on a 1024pt canvas.
SQUARE = (100, 100, 924, 924)
CORNER_RADIUS = 185

# background gradient, top -> bottom
BG_TOP = (46, 54, 72)
BG_BOTTOM = (19, 23, 32)

# ink colour for the rule
INK = (242, 245, 250)

STROKE_WIDTH = 68

# Three text lines: the top two are dashed (thoughts in flight), the last one
# resolves into a solid rule (a composed paragraph). Ragged right edges keep
# the "taking shape" rhythm.
ROWS = [
    # (y, dashes, solid_end or None)
    (366, [(240, 380), (416, 556)], None),
    (506, [(240, 394), (430, 584)], None),
    (646, [], 784),
]


def s(value: float) -> int:
    """Scale a design-space coordinate into supersampled pixels."""
    return int(round(value * SUPERSAMPLE))


def build_background(size: int) -> Image.Image:
    """Rounded square filled with a vertical gradient."""
    grad = Image.new("RGB", (1, size))
    for y in range(size):
        t = (y / (size - 1)) ** 0.85
        grad.putpixel(
            (0, y),
            tuple(round(BG_TOP[i] + (BG_BOTTOM[i] - BG_TOP[i]) * t) for i in range(3)),
        )
    grad = grad.resize((size, size), Image.NEAREST)

    mask = Image.new("L", (size, size), 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        [s(SQUARE[0]), s(SQUARE[1]), s(SQUARE[2]), s(SQUARE[3])],
        radius=s(CORNER_RADIUS),
        fill=255,
    )

    image = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    image.paste(grad, (0, 0), mask)
    return image


def stroke(x1: float, x2: float, draw: ImageDraw.ImageDraw, y: float) -> None:
    """A single round-capped horizontal stroke from x1 to x2."""
    radius = STROKE_WIDTH / 2.0
    draw.rounded_rectangle(
        [s(x1), s(y - radius), s(x2), s(y + radius)],
        radius=s(radius),
        fill=INK,
    )


def render_master() -> Image.Image:
    size = CANVAS * SUPERSAMPLE
    image = build_background(size)
    draw = ImageDraw.Draw(image)

    for y, dashes, solid_end in ROWS:
        for x1, x2 in dashes:
            stroke(x1, x2, draw, y)
        if solid_end is not None:
            stroke(240, solid_end, draw, y)

    return image.resize((CANVAS, CANVAS), Image.LANCZOS)


def main() -> None:
    out_dir = Path(sys.argv[1]) if len(sys.argv) > 1 else Path("/tmp/wtmd_icon")
    out_dir.mkdir(parents=True, exist_ok=True)

    master = render_master()
    preview = out_dir / "preview-1024.png"
    master.save(preview)
    print(f"preview  -> {preview}")

    iconset = out_dir / "AppIcon.iconset"
    iconset.mkdir(exist_ok=True)
    for logical in (16, 32, 128, 256, 512):
        for scale, suffix in ((1, ""), (2, "@2x")):
            px = logical * scale
            name = f"icon_{logical}x{logical}{suffix}.png"
            master.resize((px, px), Image.LANCZOS).save(iconset / name)
    print(f"iconset  -> {iconset}")

    icns = out_dir / "AppIcon.icns"
    subprocess.run(
        ["iconutil", "-c", "icns", str(iconset), "-o", str(icns)],
        check=True,
    )
    print(f"icns     -> {icns} ({os.path.getsize(icns)} bytes)")


if __name__ == "__main__":
    main()
