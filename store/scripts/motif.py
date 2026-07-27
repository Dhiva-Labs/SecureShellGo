"""Shared drawing helpers for SecureShell Go store graphics.

Every store asset reuses the same ">_" terminal-prompt motif and the same
dark/green palette the app itself uses (see lib/theme.dart:
``terminalBackground = 0xFF0D1117``, ``accent = 0xFF3FB950``), so the icon,
the feature graphic and any future asset stay visually consistent with the
app and with android/app/src/main/res/mipmap-*/ic_launcher.png (sampled to
confirm the exact background/green values below).

Everything is drawn as vector shapes (polygons + circles for capsule/rounded
strokes) at a supersampled resolution and downsampled with LANCZOS, so edges
stay crisp at any output size instead of being a low-res bitmap stretched up.
"""

from __future__ import annotations

import math
from dataclasses import dataclass

from PIL import Image, ImageDraw

# --- Palette -----------------------------------------------------------
# Matches lib/theme.dart exactly (AppTheme.terminalBackground / .surface /
# .accent / .danger) and android/app/src/main/res/mipmap-xxxhdpi/ic_launcher.png
# (sampled: background (13,17,23), green (63,185,80)).
BG_DARK = (13, 17, 23)  # 0xFF0D1117 - AppTheme.terminalBackground
SURFACE = (22, 27, 34)  # 0xFF161B22 - AppTheme.surface
GREEN = (63, 185, 80)  # 0xFF3FB950 - AppTheme.accent
GREEN_BRIGHT = (86, 211, 100)  # 0xFF56D364 - AppTheme.terminalTheme.brightGreen
FOREGROUND = (201, 209, 217)  # 0xFFC9D1D9 - AppTheme.terminalTheme.foreground


def _normalize(v):
    length = math.hypot(v[0], v[1])
    return (v[0] / length, v[1] / length) if length else (0.0, 0.0)


def _miter_point(vertex, n1, n2, half_width):
    """Where the two offset lines (each pushed out by ``n1``/``n2``) meet.

    Standard line-stroke miter join: push the vertex along the normalized
    bisector of the two segment normals by ``half_width / cos(theta/2)``,
    where ``theta`` is the angle between the normals. Falls back to a plain
    perpendicular offset if the segments are (near) parallel, since the
    bisector is degenerate there.
    """
    bisector = _normalize((n1[0] + n2[0], n1[1] + n2[1]))
    if bisector == (0.0, 0.0):
        return (vertex[0] + n1[0] * half_width, vertex[1] + n1[1] * half_width)
    cos_half_angle = bisector[0] * n1[0] + bisector[1] * n1[1]
    cos_half_angle = max(abs(cos_half_angle), 1e-3) * (
        1 if cos_half_angle >= 0 else -1
    )
    length = half_width / cos_half_angle
    return (vertex[0] + bisector[0] * length, vertex[1] + bisector[1] * length)


def _chevron_polygon(a, vertex, b, width):
    """A sharp-tipped chevron ribbon through ``a -> vertex -> b``.

    Unlike two capsules glued together (which rounds the vertex into a
    blob), this offsets each of the two segments by half the stroke width
    and joins them with a proper miter at ``vertex``: one corner lands past
    the vertex on the convex side (the sharp tip), the other on the concave
    side (the inner corner) — exactly what the shipping launcher icon's
    chevron looks like at the point. `a_side1`/`b_side1` (both offset by the
    segments' own `+n`) meet at `miter_pos` by construction, and likewise
    `a_side2`/`b_side2` meet at `miter_neg`, so the hexagon below is correct
    regardless of which side ends up being the tip.
    """
    half = width / 2
    d1 = _normalize((vertex[0] - a[0], vertex[1] - a[1]))
    d2 = _normalize((b[0] - vertex[0], b[1] - vertex[1]))
    n1 = (-d1[1], d1[0])
    n2 = (-d2[1], d2[0])

    miter_pos = _miter_point(vertex, n1, n2, half)
    miter_neg = _miter_point(vertex, (-n1[0], -n1[1]), (-n2[0], -n2[1]), half)

    a_side1 = (a[0] + n1[0] * half, a[1] + n1[1] * half)
    a_side2 = (a[0] - n1[0] * half, a[1] - n1[1] * half)
    b_side1 = (b[0] + n2[0] * half, b[1] + n2[1] * half)
    b_side2 = (b[0] - n2[0] * half, b[1] - n2[1] * half)

    return [a_side1, miter_pos, b_side1, b_side2, miter_neg, a_side2]


def _capsule(draw: ImageDraw.ImageDraw, p1, p2, width: float, fill) -> None:
    """A filled rectangle plus circular caps at both ends.

    Two capsules that share an endpoint produce a smooth rounded joint there
    (the caps overlap exactly), which is what makes the chevron's vertex read
    as one continuous stroke rather than two rectangles butting together.
    """
    x1, y1 = p1
    x2, y2 = p2
    length = math.hypot(x2 - x1, y2 - y1)
    r = width / 2
    if length == 0:
        draw.ellipse([x1 - r, y1 - r, x1 + r, y1 + r], fill=fill)
        return
    nx = -(y2 - y1) / length * r
    ny = (x2 - x1) / length * r
    poly = [
        (x1 + nx, y1 + ny),
        (x2 + nx, y2 + ny),
        (x2 - nx, y2 - ny),
        (x1 - nx, y1 - ny),
    ]
    draw.polygon(poly, fill=fill)
    draw.ellipse([x1 - r, y1 - r, x1 + r, y1 + r], fill=fill)
    draw.ellipse([x2 - r, y2 - r, x2 + r, y2 + r], fill=fill)


@dataclass(frozen=True)
class PromptGlyph:
    """Normalized (0..1) geometry of the ">_" prompt motif.

    Proportions were reverse-measured from the shipping launcher icon (green
    pixel bounding box ~16-83% x, ~28-71% y of the 192px source; stroke
    thickness ~9-10% of canvas) and then cleaned up into exact numbers so the
    shape can be redrawn crisply at any resolution instead of upscaling the
    existing bitmap.
    """

    stroke: float = 0.108
    vertex: tuple = (0.560, 0.465)
    top_end: tuple = (0.220, 0.240)
    bottom_end: tuple = (0.220, 0.665)
    underscore_start: tuple = (0.440, 0.690)
    underscore_end: tuple = (0.815, 0.690)


GLYPH = PromptGlyph()


def draw_prompt_glyph(
    draw: ImageDraw.ImageDraw,
    box: tuple,
    color,
    glyph: PromptGlyph = GLYPH,
) -> None:
    """Draws the ">_" chevron+underscore motif inside ``box`` = (x0, y0, x1, y1).

    Coordinates in ``glyph`` are fractions of the box's width, scaled
    uniformly (the box should be square, as both the icon and the feature
    graphic's watermark placement pass one).
    """
    x0, y0, x1, y1 = box
    size = x1 - x0

    def pt(p):
        return (x0 + p[0] * size, y0 + p[1] * size)

    stroke_w = glyph.stroke * size
    r = stroke_w / 2

    top_end = pt(glyph.top_end)
    vertex = pt(glyph.vertex)
    bottom_end = pt(glyph.bottom_end)

    draw.polygon(_chevron_polygon(top_end, vertex, bottom_end, stroke_w), fill=color)
    # Round caps at the two open arm ends only — the vertex is a miter, not
    # a cap, so it stays sharp instead of being rounded into a blob.
    for end in (top_end, bottom_end):
        draw.ellipse(
            [end[0] - r, end[1] - r, end[0] + r, end[1] + r], fill=color
        )

    _capsule(
        draw,
        pt(glyph.underscore_start),
        pt(glyph.underscore_end),
        stroke_w,
        color,
    )


def new_supersampled(width: int, height: int, factor: int, fill):
    """An RGBA canvas ``factor``x the final size, ready for crisp downsampling."""
    return Image.new("RGBA", (width * factor, height * factor), fill)


def downsample(img: Image.Image, width: int, height: int) -> Image.Image:
    return img.resize((width, height), Image.LANCZOS)
