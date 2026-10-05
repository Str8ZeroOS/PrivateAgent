#!/usr/bin/env python3
"""Generate Str8ZeRO App Store icons (opaque RGB PNG, no alpha).

Default: dark placeholder with a bold S0 monogram.
Replace later: python3 Scripts/generate-app-icon.py --from-png path/to/1024.png
"""

from __future__ import annotations

import argparse
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parents[1]
ICONSET = ROOT / "Apps" / "PrivateAgentiOS" / "Assets.xcassets" / "AppIcon.appiconset"

# idiom / scale / point-size → pixel file
SIZES = {
    "AppIcon-1024.png": 1024,
    "AppIcon-180.png": 180,
    "AppIcon-167.png": 167,
    "AppIcon-152.png": 152,
    "AppIcon-120.png": 120,
}

CONTENTS = """\
{
  "images" : [
    {
      "filename" : "AppIcon-1024.png",
      "idiom" : "universal",
      "platform" : "ios",
      "size" : "1024x1024"
    },
    {
      "filename" : "AppIcon-120.png",
      "idiom" : "iphone",
      "scale" : "2x",
      "size" : "60x60"
    },
    {
      "filename" : "AppIcon-180.png",
      "idiom" : "iphone",
      "scale" : "3x",
      "size" : "60x60"
    },
    {
      "filename" : "AppIcon-152.png",
      "idiom" : "ipad",
      "scale" : "2x",
      "size" : "76x76"
    },
    {
      "filename" : "AppIcon-167.png",
      "idiom" : "ipad",
      "scale" : "2x",
      "size" : "83.5x83.5"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
"""


def load_font(size: int) -> ImageFont.FreeTypeFont | ImageFont.ImageFont:
    candidates = [
        "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
        "/usr/share/fonts/truetype/liberation/LiberationSans-Bold.ttf",
        "/System/Library/Fonts/Supplemental/Arial Bold.ttf",
        "/Library/Fonts/Arial Bold.ttf",
    ]
    for path in candidates:
        if Path(path).is_file():
            return ImageFont.truetype(path, size=size)
    return ImageFont.load_default()


def make_placeholder(size: int = 1024) -> Image.Image:
    image = Image.new("RGB", (size, size), (11, 18, 32))
    draw = ImageDraw.Draw(image)
    inset = int(size * 0.12)
    draw.rounded_rectangle(
        (inset, inset, size - inset, size - inset),
        radius=int(size * 0.18),
        fill=(20, 48, 64),
    )
    font = load_font(int(size * 0.38))
    text = "S0"
    bbox = draw.textbbox((0, 0), text, font=font)
    text_w = bbox[2] - bbox[0]
    text_h = bbox[3] - bbox[1]
    x = (size - text_w) / 2 - bbox[0]
    y = (size - text_h) / 2 - bbox[1] - int(size * 0.02)
    draw.text((x, y), text, font=font, fill=(232, 241, 248))
    return image


def assert_opaque_rgb(image: Image.Image, name: str) -> None:
    if image.mode != "RGB":
        raise SystemExit(f"{name} must be RGB (no alpha); got {image.mode}")
    if image.mode in {"RGBA", "LA", "PA"} or "A" in image.getbands():
        raise SystemExit(f"{name} has an alpha channel; App Store rejects transparent icons")


def write_iconset(master: Image.Image) -> None:
    ICONSET.mkdir(parents=True, exist_ok=True)
    master = master.convert("RGB")
    assert_opaque_rgb(master, "master")
    for name, edge in SIZES.items():
        resized = master.resize((edge, edge), Image.Resampling.LANCZOS).convert("RGB")
        assert_opaque_rgb(resized, name)
        path = ICONSET / name
        resized.save(path, format="PNG")
        print(f"wrote {path} {resized.size} {resized.mode}")
    (ICONSET / "Contents.json").write_text(CONTENTS, encoding="utf-8")
    catalog = ICONSET.parent / "Contents.json"
    if not catalog.exists():
        catalog.write_text(
            '{\n  "info" : {\n    "author" : "xcode",\n    "version" : 1\n  }\n}\n',
            encoding="utf-8",
        )


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--from-png",
        type=Path,
        help="Replace the placeholder with your own opaque 1024x1024 (or larger) PNG",
    )
    args = parser.parse_args()
    if args.from_png:
        master = Image.open(args.from_png).convert("RGB")
    else:
        master = make_placeholder(1024)
    write_iconset(master)


if __name__ == "__main__":
    main()
