#!/usr/bin/env python3
"""Install an image as colon3's app icon.

    python3 scripts/set-icon.py ~/Pictures/colon3.png

Makes it a square 1024x1024 opaque PNG (iOS draws transparent pixels as black), centring
and cropping if needed. Needs Pillow: `sudo pacman -S python-pillow` or `pip install pillow`.
"""

import sys
from pathlib import Path

from PIL import Image

TARGET = Path(__file__).resolve().parent.parent / "App/Assets.xcassets/AppIcon.appiconset/AppIcon.png"


def main() -> None:
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    image = Image.open(sys.argv[1])
    if image.mode in ("RGBA", "LA", "P"):
        rgba = image.convert("RGBA")
        background = Image.new("RGBA", rgba.size, (0, 0, 0, 255))
        background.alpha_composite(rgba)
        image = background
    image = image.convert("RGB")

    side = min(image.size)
    left = (image.width - side) // 2
    top = (image.height - side) // 2
    image = image.crop((left, top, left + side, top + side)).resize((1024, 1024), Image.LANCZOS)
    image.save(TARGET, optimize=True)
    print(f"Wrote {TARGET.relative_to(Path.cwd()) if TARGET.is_relative_to(Path.cwd()) else TARGET}")


if __name__ == "__main__":
    main()
