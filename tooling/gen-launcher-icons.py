#!/usr/bin/env python3
"""Launcher icons for the phone build, from the official DSH app art.

The art is `app/assets/brand/dsh-icon-512.png`, the icon the official web app
ships (`icon-512.png` in dsh-web-frontend): a near-white rounded square with the
dark whale. It is the same picture the browser tab and the installed PWA show,
so the phone's launcher matches the app it opens into.

Writes, per density:

  mipmap-<dpi>/ic_launcher.png                  the art at the launcher's size
  mipmap-<dpi>/ic_launcher_round.png            the same, cropped to a circle
  mipmap-<dpi>/ic_launcher_foreground.png       adaptive foreground: the art in
                                                 the 66dp safe zone of the
                                                 108dp canvas, on transparency
  ...and the same three for the _frost / _ink / _night icon styles, which all
  carry the official art now.

plus `drawable/ic_launcher*_background.xml`, a solid colour behind the art.

Run from the repository root: python3 tooling/gen-launcher-icons.py
"""

from pathlib import Path

from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parent.parent
ART = ROOT / "app/assets/brand/dsh-icon-512.png"
RES = ROOT / "app/android/app/src/main/res"
COLOR = Image.open(ART).convert("RGB").getpixel((8, 8))
BACKGROUND = "#%02X%02X%02X" % COLOR

# Launcher density buckets and each one's full-icon pixel size.
DENSITIES = {"mdpi": 48, "hdpi": 72, "xhdpi": 96, "xxhdpi": 144, "xxxhdpi": 192}
# The adaptive canvas is 108dp; the art sits in the 66dp safe zone, which the
# system then masks into whatever shape the launcher uses.
SAFE = 66 / 108
STYLES = ("", "_frost", "_ink", "_night")

BACKGROUND_XML = """<?xml version="1.0" encoding="utf-8"?>
<!-- Launcher background: the official dsh icon's own colour, one flat fill so
     the art's square edge disappears into it inside the adaptive mask. -->
<vector xmlns:android="http://schemas.android.com/apk/res/android"
    android:width="108dp"
    android:height="108dp"
    android:viewportWidth="108"
    android:viewportHeight="108">
    <path
        android:pathData="M0,0h108v108h-108z"
        android:fillColor="{color}" />
</vector>
"""


def rounded(size: int, art: Image.Image) -> Image.Image:
    return art.resize((size, size), Image.LANCZOS)


def circular(size: int, art: Image.Image) -> Image.Image:
    image = rounded(size * 4, art)
    mask = Image.new("L", image.size, 0)
    ImageDraw.Draw(mask).ellipse((0, 0, image.size[0] - 1, image.size[1] - 1), fill=255)
    out = Image.new("RGBA", image.size, (0, 0, 0, 0))
    out.paste(image, (0, 0), mask)
    return out.resize((size, size), Image.LANCZOS)


def foreground(size: int, art: Image.Image) -> Image.Image:
    canvas = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    side = round(size * SAFE)
    offset = (size - side) // 2
    canvas.paste(rounded(side, art), (offset, offset))
    return canvas


def main() -> None:
    art = Image.open(ART).convert("RGBA")
    if art.size != (512, 512):
        raise SystemExit(f"art is {art.size}, expected 512x512")
    for bucket, size in DENSITIES.items():
        folder = RES / f"mipmap-{bucket}"
        folder.mkdir(parents=True, exist_ok=True)
        for style in STYLES:
            rounded(size, art).save(folder / f"ic_launcher{style}.png", optimize=True)
            circular(size, art).save(folder / f"ic_launcher{style}_round.png", optimize=True)
            # The adaptive foreground is 108dp of canvas at the same density.
            ratio = size / 48  # 48dp is one mdpi launcher square
            foreground(round(108 * ratio), art).save(
                folder / f"ic_launcher{style}_foreground.png", optimize=True
            )
        print(f"{bucket}: launcher {size}px, foreground {round(108 * size / 48)}px")
    for style in STYLES:
        drawable = RES / "drawable"
        drawable.mkdir(parents=True, exist_ok=True)
        (drawable / f"ic_launcher{style}_background.xml").write_text(
            BACKGROUND_XML.format(color=BACKGROUND), encoding="utf-8"
        )
    print(f"backgrounds: {BACKGROUND}")


if __name__ == "__main__":
    main()
