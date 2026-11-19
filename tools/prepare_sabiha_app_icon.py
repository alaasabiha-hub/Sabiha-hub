"""Prepare native Sabiha Hub icons from the latest approved transparent image.

Only crops transparent canvas and resamples the supplied art. It never redraws,
recolors, or edits the logo itself. Android legacy icons keep alpha; iOS is
flattened over a matching deep-blue background as required by iOS.
"""
from __future__ import annotations

import hashlib
import json
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "assets/sabiha_app_icon_reference.png"
EXPECTED_SOURCE_SHA256 = "d35ddd1cb47201fd82d22e04f7116b166d59bc0594d89b7910bada00499032be"
EXPECTED_SIZE = (1254, 1254)
ALPHA_THRESHOLD = 8  # Ignore isolated near-transparent specks outside the tile.
SAFE_PADDING = 2  # Preserve only a few antialias pixels; avoid an inset second frame.
ANDROID_ADAPTIVE_SCALE = 0.66  # Android's 66% central safe zone keeps every wordmark edge clear.
# Matching the tile's deep-blue outer edge keeps iOS's required opaque corners
# visually continuous with the supplied artwork.
IOS_BACKGROUND = (6, 26, 75, 255)

source_bytes = SOURCE.read_bytes()
source_hash = hashlib.sha256(source_bytes).hexdigest()
if source_hash != EXPECTED_SOURCE_SHA256:
    raise SystemExit("The approved icon reference changed; review it before generating assets")
source = Image.open(SOURCE).convert("RGBA")
if source.size != EXPECTED_SIZE:
    raise SystemExit(f"Unexpected approved source dimensions: {source.size}")

alpha = source.getchannel("A")
mask = alpha.point(lambda value: 255 if value >= ALPHA_THRESHOLD else 0)
bounds = mask.getbbox()
if bounds is None:
    raise SystemExit("The approved icon image has no visible pixels")
left, top, right, bottom = bounds
side = max(right - left, bottom - top) + SAFE_PADDING * 2
center_x = (left + right) / 2
center_y = (top + bottom) / 2
crop_left = round(center_x - side / 2)
crop_top = round(center_y - side / 2)
tile = source.crop((crop_left, crop_top, crop_left + side, crop_top + side))
master = tile.resize((1024, 1024), Image.Resampling.LANCZOS)


def save(image: Image.Image, path: Path, size: int, *, mode: str = "RGBA") -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    resized = image.resize((size, size), Image.Resampling.LANCZOS)
    if mode == "RGB":
        background = Image.new("RGBA", resized.size, IOS_BACKGROUND)
        background.alpha_composite(resized)
        resized = background.convert("RGB")
    elif mode == "RGBA":
        resized = resized.convert("RGBA")
    resized.save(path, format="PNG", optimize=True)


master_path = ROOT / "assets/sabiha_app_icon_cropped.png"
master.save(master_path, format="PNG", optimize=True)

# Some launchers still resolve legacy density icons and apply a circular mask.
# Keep the same artwork within that safe circle too; the matching opaque blue
# fill prevents a white halo where the legacy format cannot retain alpha.
res = ROOT / "android/app/src/main/res"
for density, pixels in (
    ("mdpi", 48),
    ("hdpi", 72),
    ("xhdpi", 96),
    ("xxhdpi", 144),
    ("xxxhdpi", 192),
):
    legacy = Image.new("RGBA", (pixels, pixels), IOS_BACKGROUND)
    legacy_size = round(pixels * ANDROID_ADAPTIVE_SCALE)
    legacy_art = master.resize((legacy_size, legacy_size), Image.Resampling.LANCZOS)
    legacy_offset = (pixels - legacy_size) // 2
    legacy.alpha_composite(legacy_art, (legacy_offset, legacy_offset))
    save(legacy, res / f"mipmap-{density}/ic_launcher.png", pixels, mode="RGB")

# Adaptive icons are clipped by each launcher's mask. Keep the complete supplied
# artwork as one proportionally scaled foreground layer inside the circle-safe
# area. A matching deep blue background fills only the outer mask; no new border
# or artwork is drawn.
for density, pixels in (
    ("mdpi", 108),
    ("hdpi", 162),
    ("xhdpi", 216),
    ("xxhdpi", 324),
    ("xxxhdpi", 432),
):
    foreground = Image.new("RGBA", (pixels, pixels), (0, 0, 0, 0))
    scaled_size = round(pixels * ANDROID_ADAPTIVE_SCALE)
    artwork = master.resize((scaled_size, scaled_size), Image.Resampling.LANCZOS)
    offset = (pixels - scaled_size) // 2
    foreground.alpha_composite(artwork, (offset, offset))
    target = res / f"mipmap-{density}/ic_launcher_foreground.png"
    target.parent.mkdir(parents=True, exist_ok=True)
    foreground.save(target, format="PNG", optimize=True)
(res / "mipmap-anydpi-v26/ic_launcher.xml").write_text(
    '''<?xml version="1.0" encoding="utf-8"?>
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
    <background android:drawable="@color/ic_launcher_background" />
    <foreground android:drawable="@mipmap/ic_launcher_foreground" />
</adaptive-icon>
''',
    encoding="utf-8",
)
(res / "values/ic_launcher_background.xml").write_text(
    '''<resources><color name="ic_launcher_background">#061A4B</color></resources>\n''',
    encoding="utf-8",
)

# Native launch assets and iOS app icons cannot use transparent icon corners.
launch_canvas = Image.new("RGBA", (720, 720), (0, 0, 0, 0))
launch_art = master.resize((round(720 * ANDROID_ADAPTIVE_SCALE),) * 2, Image.Resampling.LANCZOS)
launch_offset = (720 - launch_art.width) // 2
launch_canvas.alpha_composite(launch_art, (launch_offset, launch_offset))
write_launch = res / "drawable-nodpi/sabiha_launch.png"
write_launch.parent.mkdir(parents=True, exist_ok=True)
launch_canvas.save(write_launch, format="PNG", optimize=True)
for folder in ("drawable", "drawable-v21"):
    (res / folder / "launch_background.xml").write_text(
        '''<?xml version="1.0" encoding="utf-8"?>
<layer-list xmlns:android="http://schemas.android.com/apk/res/android">
    <item android:drawable="@color/sabiha_navy" />
    <item android:width="200dp" android:height="200dp" android:gravity="center" android:drawable="@drawable/sabiha_launch" />
</layer-list>
''',
        encoding="utf-8",
    )

icons = ROOT / "ios/Runner/Assets.xcassets/AppIcon.appiconset"
catalog = json.loads((icons / "Contents.json").read_text(encoding="utf-8"))
for entry in catalog["images"]:
    pixels = round(float(entry["size"].split("x")[0]) * float(entry["scale"].removesuffix("x")))
    save(master, icons / entry["filename"], pixels, mode="RGB")

launch = ROOT / "ios/Runner/Assets.xcassets/LaunchImage.imageset"
for scale in (1, 2, 3):
    save(master, launch / ("LaunchImage" + (f"@{scale}x" if scale > 1 else "") + ".png"), 200 * scale)

# Light/dark contrast proofs are generated locally for visual review.
proofs = ROOT / "build/staging/icon-previews"
proofs.mkdir(parents=True, exist_ok=True)
for name, color in (("white", (255, 255, 255, 255)), ("navy", (7, 26, 54, 255))):
    preview = Image.new("RGBA", master.size, color)
    preview.alpha_composite(master)
    preview.convert("RGB").save(proofs / f"sabiha-icon-{name}.png", optimize=True)

# Launcher-mask proofs mirror the two common shapes. These are for sizing QA;
# device screenshots are captured separately from Android/iOS simulators.
adaptive_art = master.resize((round(1024 * ANDROID_ADAPTIVE_SCALE),) * 2, Image.Resampling.LANCZOS)
adaptive_canvas = Image.new("RGBA", (1024, 1024), IOS_BACKGROUND)
adaptive_canvas.alpha_composite(adaptive_art, ((1024 - adaptive_art.width) // 2,) * 2)
circle_mask = Image.new("L", (1024, 1024), 0)
from PIL import ImageDraw

ImageDraw.Draw(circle_mask).ellipse((61, 61, 962, 962), fill=255)
circle = adaptive_canvas.copy()
circle.putalpha(circle_mask)
circle_preview = Image.new("RGBA", (1024, 1024), IOS_BACKGROUND)
circle_preview.alpha_composite(circle)
circle_preview.convert("RGB").save(proofs / "sabiha-icon-adaptive-circle.png", optimize=True)
one_ui_mask = Image.new("L", (1024, 1024), 0)
ImageDraw.Draw(one_ui_mask).rounded_rectangle((20, 20, 1003, 1003), radius=235, fill=255)
one_ui = adaptive_canvas.copy()
one_ui.putalpha(one_ui_mask)
one_ui_preview = Image.new("RGBA", (1024, 1024), IOS_BACKGROUND)
one_ui_preview.alpha_composite(one_ui)
one_ui_preview.convert("RGB").save(proofs / "sabiha-icon-adaptive-oneui.png", optimize=True)

if hashlib.sha256(SOURCE.read_bytes()).hexdigest() != EXPECTED_SOURCE_SHA256:
    raise SystemExit("The approved icon reference changed during generation")
print(
    "Prepared approved transparent icon; "
    f"sha256={source_hash}; alpha_bounds={bounds}; square_crop="
    f"({crop_left},{crop_top},{crop_left + side},{crop_top + side}); "
    f"adaptive_scale={ANDROID_ADAPTIVE_SCALE}"
)
