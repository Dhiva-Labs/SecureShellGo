"""Generates store/graphics/feature-graphic-1024x500.png for Play Console.

Play feature graphic requirements this satisfies:
  * Exactly 1024 x 500 px
  * 24-bit PNG (opaque — no alpha channel), which is one of Play's two
    accepted formats for this asset (the other being JPG)
  * No screenshots, device frames or fake UI baked in — the "terminal"
    suggestion is an abstract oversized ">_" watermark, not a rendered
    window
  * No claims/marketing text, just the app name and a short factual tagline
  * The lower-left corner is left calm (background gradient only) because
    Play overlays the app icon + title chip there when this graphic is
    shown as a promotional card

Palette and the ">_" motif are shared with make_icon.py via motif.py, so
this reads as the same app, not a separate piece of marketing art.

Run: python3 store/scripts/make_feature_graphic.py
"""

from __future__ import annotations

import random
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

from motif import (
    BG_DARK,
    FOREGROUND,
    GREEN,
    GREEN_BRIGHT,
    SURFACE,
    downsample,
    draw_prompt_glyph,
)

OUT_W, OUT_H = 1024, 500
SUPERSAMPLE = 2
W, H = OUT_W * SUPERSAMPLE, OUT_H * SUPERSAMPLE

FONT_BOLD = "/usr/share/fonts/truetype/dejavu/DejaVuSansMono-Bold.ttf"
FONT_REGULAR = "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf"

OUT_PATH = Path(__file__).resolve().parent.parent / "graphics" / "feature-graphic-1024x500.png"


def _lerp(a, b, t):
    return tuple(round(a[i] + (b[i] - a[i]) * t) for i in range(3))


def _background(w, h):
    """Diagonal gradient between the app's two dark surfaces.

    The two colours are close (a 9-11 level difference per channel), so a
    plain 8-bit lerp bands visibly once zoomed in — a `random.seed`ed +/-1
    dither breaks that up into fine grain without changing the average
    colour, and stays reproducible across regenerations.
    """
    rng = random.Random(20260728)  # fixed seed: pixel-identical reruns
    img = Image.new("RGB", (w, h), BG_DARK)
    px = img.load()
    for y in range(h):
        row_t = y / h
        left = _lerp(BG_DARK, SURFACE, row_t * 0.6)
        right = _lerp(SURFACE, BG_DARK, row_t * 0.3)
        for x in range(w):
            t = x / w
            r, g, b = _lerp(left, right, t)
            n = rng.randint(-1, 1)
            px[x, y] = (
                min(255, max(0, r + n)),
                min(255, max(0, g + n)),
                min(255, max(0, b + n)),
            )
    return img


def _scanlines(w, h, box):
    """Faint horizontal lines confined to `box`, suggesting a CRT/terminal
    without drawing an actual window — kept out of the text and the
    Play-overlay safe zone."""
    overlay = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    draw = ImageDraw.Draw(overlay)
    x0, y0, x1, y1 = box
    step = max(1, round(6 * SUPERSAMPLE))
    for y in range(int(y0), int(y1), step):
        draw.line([(x0, y), (x1, y)], fill=(*GREEN, 10), width=1)
    return overlay


def _text_width(draw, text, font):
    bbox = draw.textbbox((0, 0), text, font=font)
    return bbox[2] - bbox[0], bbox[3] - bbox[1]


def build() -> Image.Image:
    base = _background(W, H).convert("RGBA")

    # Oversized watermark motif on the right, low alpha, partly bleeding off
    # the top/right edge so it reads as "big terminal cursor in the room"
    # rather than a centered logo.
    glyph_size = int(H * 0.86)
    glyph_box = (
        W - int(glyph_size * 0.92),
        int(H * 0.08),
        W - int(glyph_size * 0.92) + glyph_size,
        int(H * 0.08) + glyph_size,
    )
    glyph_layer = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    glyph_draw = ImageDraw.Draw(glyph_layer)
    draw_prompt_glyph(glyph_draw, glyph_box, (*GREEN, 46))
    base = Image.alpha_composite(base, glyph_layer)

    # Subtle scanline texture, confined to the right two-thirds so the title
    # stays on clean background and the lower-left stays calm for Play's
    # overlay.
    scan_box = (W * 0.30, 0, W, H)
    base = Image.alpha_composite(base, _scanlines(W, H, scan_box))

    draw = ImageDraw.Draw(base)

    margin = int(56 * SUPERSAMPLE)
    title_font = ImageFont.truetype(FONT_BOLD, int(78 * SUPERSAMPLE))
    tagline_font = ImageFont.truetype(FONT_REGULAR, int(30 * SUPERSAMPLE))

    title = "SecureShell Go"
    title_x, title_y = margin, int(72 * SUPERSAMPLE)
    draw.text((title_x, title_y), title, font=title_font, fill=(240, 246, 252))

    title_w, title_h = _text_width(draw, title, title_font)

    # A small blinking-cursor block right after the title text, like an
    # unfinished prompt line — ties back to the ">_" motif typographically
    # instead of repeating the glyph shape again.
    cursor_w = int(30 * SUPERSAMPLE)
    cursor_h = int(title_h * 1.05)
    cursor_x0 = title_x + title_w + int(18 * SUPERSAMPLE)
    cursor_y0 = title_y + int(title_h * 0.02)
    draw.rectangle(
        [cursor_x0, cursor_y0, cursor_x0 + cursor_w, cursor_y0 + cursor_h],
        fill=GREEN,
    )

    tagline = "SSH terminal & SFTP client for Android"
    tagline_y = title_y + int(title_h * 1.55)
    draw.text(
        (title_x, tagline_y), tagline, font=tagline_font, fill=GREEN_BRIGHT
    )
    tagline_w, tagline_h = _text_width(draw, tagline, tagline_font)

    # Short accent rule under the tagline — a small typographic flourish,
    # not a claim, not UI chrome.
    rule_y = tagline_y + tagline_h + int(22 * SUPERSAMPLE)
    rule_w = int(120 * SUPERSAMPLE)
    draw.line(
        [(title_x, rule_y), (title_x + rule_w, rule_y)],
        fill=(*GREEN, 200) if False else GREEN,
        width=int(4 * SUPERSAMPLE),
    )

    # Second, muted line: what it's for, in the app's own terminal foreground
    # colour rather than the accent, so it reads as secondary.
    detail = "Trust-on-first-use host keys  ·  Keystore-encrypted credentials"
    detail_font = ImageFont.truetype(FONT_REGULAR, int(22 * SUPERSAMPLE))
    detail_y = rule_y + int(26 * SUPERSAMPLE)
    draw.text((title_x, detail_y), detail, font=detail_font, fill=FOREGROUND)

    return base.convert("RGB")


def main() -> None:
    img = build()
    final = downsample(img, OUT_W, OUT_H)
    if final.mode != "RGB":
        final = final.convert("RGB")

    OUT_PATH.parent.mkdir(parents=True, exist_ok=True)
    final.save(OUT_PATH, format="PNG")

    with Image.open(OUT_PATH) as check:
        check.load()
        assert check.size == (OUT_W, OUT_H), check.size
        assert check.mode == "RGB", check.mode
        assert "A" not in check.getbands(), check.getbands()
    size_bytes = OUT_PATH.stat().st_size
    print(
        f"wrote {OUT_PATH} "
        f"({check.size[0]}x{check.size[1]}, mode={check.mode}, "
        f"{size_bytes:,} bytes)"
    )


if __name__ == "__main__":
    main()
