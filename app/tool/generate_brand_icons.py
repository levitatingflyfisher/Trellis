#!/usr/bin/env python3
"""Regenerates every platform icon from assets/brand/trellis-logo.svg.

Campaign 9 Phase 8 ("identity: the lattice everywhere"): every mipmap AND
the PWA icons shipped byte-identical to Flutter's stock template — no logo
asset existed in the repo at all. This script is the one place that fact
gets fixed, deterministically: run it again any time the logo SVG changes
and every derived PNG regenerates the same way.

Usage: `python3 tool/generate_brand_icons.py` from the `app/` directory
(paths below are relative to this file's parent, so it also works run
from elsewhere). Requires cairosvg + Pillow (both already on this box —
see the sibling ADR/docs note on why no SVG-rasterizer CLI was needed).

Colors: the SVG's own two stroke colors (`#C47B6A` clay, `#A85040` hearth
red) plus a warm-paper background tone this script computes ONCE below —
the same 16% clay-over-white blend the SVG's own translucent background
rect already expresses, made opaque for the adaptive-icon background
layer (which cannot itself carry transparency).
"""
from __future__ import annotations

import io
import xml.etree.ElementTree as ET
from pathlib import Path

import cairosvg
from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
SVG_PATH = ROOT / "assets" / "brand" / "trellis-logo.svg"
SVG_SOURCE = SVG_PATH.read_text(encoding="utf-8")

CLAY = (0xC4, 0x7B, 0x6A)
HEARTH_RED = (0xA8, 0x50, 0x40)

# The SVG's own background rect: CLAY at 16% opacity over white. Composited
# here to an OPAQUE color for adaptive-icon backgrounds and any other layer
# that cannot itself carry alpha — this IS "a warm paper tone consistent
# with the 16% tint" the spec asks for, not a separately chosen color.
def _blend_over_white(rgb: tuple[int, int, int], alpha: float) -> tuple[int, int, int]:
    return tuple(round(255 * (1 - alpha) + c * alpha) for c in rgb)


PAPER_BG = _blend_over_white(CLAY, 0.16)  # (246, 234, 231)

# Android's adaptive-icon safe zone: content inside a 66dp circle survives
# EVERY launcher mask shape on a 108dp canvas (the OS-documented figure;
# see mipmap-anydpi-v26/ic_launcher.xml's own layers below). The W3C
# maskable-icon guidance for the PWA manifest is looser (an 80%-diameter
# safe circle) -- both are expressed here as the fraction of the output
# canvas the glyph's own 512 viewBox is scaled down to, centered.
ANDROID_SAFE_FRACTION = 66 / 108
MASKABLE_SAFE_FRACTION = 0.8

# Android launcher legacy + adaptive-icon density buckets (density name ->
# (legacy px, adaptive-canvas px)). The adaptive canvas is always
# legacy_px * (108/48) -- Android's own 108dp-canvas-for-a-48dp-icon ratio,
# applied per density bucket exactly as legacy launcher icons already are.
DENSITIES = {
    "mdpi": 48,
    "hdpi": 72,
    "xhdpi": 96,
    "xxhdpi": 144,
    "xxxhdpi": 192,
}

# Notification small-icon densities (Android's 24dp base, same bucket
# ratios as the launcher table above).
NOTIFICATION_DENSITIES = {
    "mdpi": 24,
    "hdpi": 36,
    "xhdpi": 48,
    "xxhdpi": 72,
    "xxxhdpi": 96,
}

ANDROID_RES = ROOT / "android" / "app" / "src" / "main" / "res"
WEB_ICONS = ROOT / "web" / "icons"


def render_svg(svg_source: str, size: int) -> Image.Image:
    """Rasterizes `svg_source` (a full `<svg>...</svg>` document) to an
    RGBA Pillow image of `size` x `size` px."""
    png_bytes = cairosvg.svg2png(
        bytestring=svg_source.encode("utf-8"),
        output_width=size,
        output_height=size,
    )
    return Image.open(io.BytesIO(png_bytes)).convert("RGBA")


def glyph_only_svg(*, monochrome: bool = False) -> str:
    """The lattice strokes alone -- no background rect -- for every layer
    that supplies its OWN background separately (adaptive foreground,
    monochrome, maskable PWA icons, the notification icon). `monochrome`
    recolors both stroke groups to a single white, matching Android's own
    contract for a themed/monochrome icon layer (the OS re-tints it; the
    asset must carry no color information of its own) and the
    notification-icon convention (white-on-transparent; Android discards
    color there too).
    """
    root = ET.fromstring(SVG_SOURCE)
    ns = "{http://www.w3.org/2000/svg}"
    for rect in root.findall(f"{ns}rect"):
        root.remove(rect)
    if monochrome:
        for g in root.findall(f"{ns}g"):
            g.set("stroke", "#FFFFFF")
    return ET.tostring(root, encoding="unicode")


def safe_zone_canvas(glyph_svg: str, canvas_size: int, glyph_fraction: float) -> Image.Image:
    """A transparent `canvas_size` square with the glyph rendered at
    `glyph_fraction` of that size, centered -- the shared shape every
    adaptive/maskable/monochrome layer below is built from."""
    glyph_px = round(canvas_size * glyph_fraction)
    glyph = render_svg(glyph_svg, glyph_px)
    canvas = Image.new("RGBA", (canvas_size, canvas_size), (0, 0, 0, 0))
    offset = (canvas_size - glyph_px) // 2
    canvas.alpha_composite(glyph, (offset, offset))
    return canvas


def solid_canvas(size: int, rgb: tuple[int, int, int]) -> Image.Image:
    return Image.new("RGBA", (size, size), (*rgb, 255))


def save(img: Image.Image, path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    img.save(path)
    print(f"  {path.relative_to(ROOT)}  {img.size[0]}x{img.size[1]}")


def generate_android_legacy() -> None:
    print("Android legacy launcher icons (full SVG, own background):")
    for density, px in DENSITIES.items():
        img = render_svg(SVG_SOURCE, px)
        save(img, ANDROID_RES / f"mipmap-{density}" / "ic_launcher.png")


def generate_android_adaptive() -> None:
    print("Android adaptive-icon layers (foreground / background / monochrome):")
    fg_svg = glyph_only_svg()
    mono_svg = glyph_only_svg(monochrome=True)
    for density, legacy_px in DENSITIES.items():
        canvas_px = round(legacy_px * 108 / 48)
        fg = safe_zone_canvas(fg_svg, canvas_px, ANDROID_SAFE_FRACTION)
        save(fg, ANDROID_RES / f"mipmap-{density}" / "ic_launcher_foreground.png")
        bg = solid_canvas(canvas_px, PAPER_BG)
        save(bg, ANDROID_RES / f"mipmap-{density}" / "ic_launcher_background.png")
        mono = safe_zone_canvas(mono_svg, canvas_px, ANDROID_SAFE_FRACTION)
        save(mono, ANDROID_RES / f"mipmap-{density}" / "ic_launcher_monochrome.png")

    xml_dir = ANDROID_RES / "mipmap-anydpi-v26"
    xml_dir.mkdir(parents=True, exist_ok=True)
    xml_path = xml_dir / "ic_launcher.xml"
    xml_path.write_text(
        '<?xml version="1.0" encoding="utf-8"?>\n'
        '<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">\n'
        '    <background android:drawable="@mipmap/ic_launcher_background"/>\n'
        '    <foreground android:drawable="@mipmap/ic_launcher_foreground"/>\n'
        '    <monochrome android:drawable="@mipmap/ic_launcher_monochrome"/>\n'
        "</adaptive-icon>\n",
        encoding="utf-8",
    )
    print(f"  {xml_path.relative_to(ROOT)}")


def generate_notification_icon() -> None:
    # UNWIRED (Campaign 9 Phase 2's media-session integration was never
    # implemented in this campaign -- see the phase's own commit and the
    # campaign report). Generated now because it costs nothing and the
    # asset is the one thing the future work needs ready; nothing in the
    # app references android/app/.../ic_notification.png yet.
    print("Android notification small icon (white-on-transparent; UNWIRED):")
    mono_svg = glyph_only_svg(monochrome=True)
    for density, px in NOTIFICATION_DENSITIES.items():
        img = render_svg(mono_svg, px)
        save(img, ANDROID_RES / f"drawable-{density}" / "ic_notification.png")


def generate_pwa_icons() -> None:
    print("PWA icons (opaque square + maskable safe-zone variants):")
    fg_svg = glyph_only_svg()
    for size in (192, 512):
        img = render_svg(SVG_SOURCE, size)
        # The source SVG's own background rect is a translucent overlay
        # (opacity .16) -- composited over the paper tone here so a PWA
        # icon (which, unlike the app-shell theme, has no guaranteed
        # backdrop of its own) is fully opaque, never showing through to
        # whatever the OS icon tray paints behind it.
        opaque = Image.alpha_composite(solid_canvas(size, PAPER_BG), img)
        save(opaque.convert("RGB"), WEB_ICONS / f"Icon-{size}.png")

        maskable = safe_zone_canvas(fg_svg, size, MASKABLE_SAFE_FRACTION)
        maskable_bg = solid_canvas(size, PAPER_BG)
        maskable_bg.alpha_composite(maskable)
        save(maskable_bg, WEB_ICONS / f"Icon-maskable-{size}.png")

    favicon = render_svg(SVG_SOURCE, 32)
    opaque_favicon = Image.alpha_composite(solid_canvas(32, PAPER_BG), favicon)
    save(opaque_favicon.convert("RGB"), ROOT / "web" / "favicon.png")


def main() -> None:
    print(f"Source: {SVG_PATH.relative_to(ROOT)}")
    print(f"Paper background (16% clay-over-white, composited opaque): {PAPER_BG}")
    generate_android_legacy()
    generate_android_adaptive()
    generate_notification_icon()
    generate_pwa_icons()


if __name__ == "__main__":
    main()
