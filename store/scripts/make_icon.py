"""Generates store/graphics/icon-512.png — the Play Console hi-res store icon.

Play Store hi-res icon requirements this satisfies:
  * 512 x 512 px exactly
  * 32-bit PNG
  * No alpha channel / transparency (Play flattens or rejects a transparent
    icon; we render straight to RGB so there is nothing to flatten)
  * No baked-in rounded corners or shadow (Play applies its own mask per
    device/launcher, so the square is left full-bleed)
  * No text beyond the app's own ">_" motif

The motif and colours are shared with make_feature_graphic.py via motif.py so
every asset stays visually identical to the shipping launcher icon
(android/app/src/main/res/mipmap-*/ic_launcher.png) and to lib/theme.dart.

Run: python3 store/scripts/make_icon.py
"""

from __future__ import annotations

from pathlib import Path

from PIL import Image, ImageDraw

from motif import BG_DARK, GREEN, downsample, draw_prompt_glyph

OUT_SIZE = 512
SUPERSAMPLE = 4  # render at 2048px, downsample for anti-aliased edges
WORK_SIZE = OUT_SIZE * SUPERSAMPLE

# Safe-zone padding: the motif's own bounding box (see motif.PromptGlyph)
# already leaves ~17-20% margin on each side, which is enough room that
# Play's circular/squircle masking on various launchers won't clip it.
GLYPH_BOX = (0, 0, WORK_SIZE, WORK_SIZE)

OUT_PATH = Path(__file__).resolve().parent.parent / "graphics" / "icon-512.png"


def build() -> Image.Image:
    canvas = Image.new("RGB", (WORK_SIZE, WORK_SIZE), BG_DARK)
    draw = ImageDraw.Draw(canvas)
    draw_prompt_glyph(draw, GLYPH_BOX, GREEN)
    return downsample(canvas, OUT_SIZE, OUT_SIZE)


def main() -> None:
    icon = build()

    # Belt-and-braces: guarantee no alpha channel made it in.
    if icon.mode != "RGB":
        icon = icon.convert("RGB")

    OUT_PATH.parent.mkdir(parents=True, exist_ok=True)
    icon.save(OUT_PATH, format="PNG")

    # Verify what actually landed on disk, not just the in-memory object.
    with Image.open(OUT_PATH) as check:
        check.load()
        assert check.size == (OUT_SIZE, OUT_SIZE), check.size
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
