"""Writes the icon artwork as SVG: the layers of the Viewer, Bridge and ViewerIOS AppIcon.icon bundles,
and the .note/.mark document icons (Artwork/build/, turned into .icns by render.sh).

The app icon is the Sumi "Brush S on washi" (see Artwork/sumi/): the S painted with a brush on washi
paper, with the indigo full stop. The brush and paper textures are SVG filters, which Icon Composer
doesn't render, so render.sh turns those two layers into PNGs with headless Chrome.

The ink stroke is a broad pen nib (an ellipse) swept along a Bézier path, so it has the thick and
thin parts of handwriting. Edit the paths or colours here and run render.sh; layer placement,
glass and shadows are set in each icon.json (Icon Composer).
"""
import math
import os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BUILD = os.path.join(ROOT, "Artwork", "build")

PAPER = "#E9E8E2"
PAPER_LIGHT = "#F2F1EC"
INK = "#151515"
RULE = "#1E1E19"
BLUE = "#2B4C8C"
SHEET = "#FFFFFF"
WASHI = "#EDE9DF"

# Brush texture: displaced (rough) edges, plus a few dry-brush gaps where streaky noise peaks.
BRUSH_FILTER = ('<filter id="brush" x="-10%" y="-10%" width="120%" height="120%">'
                '<feTurbulence type="fractalNoise" baseFrequency="0.03" numOctaves="3" seed="3" result="n"/>'
                '<feDisplacementMap in="SourceGraphic" in2="n" scale="9" xChannelSelector="R" yChannelSelector="G" '
                'result="d"/>'
                '<feTurbulence type="fractalNoise" baseFrequency="0.004 0.09" numOctaves="2" seed="11" result="s"/>'
                '<feColorMatrix in="s" values="0 0 0 0 0  0 0 0 0 0  0 0 0 0 0  0 0 0 -11 8.3" result="m"/>'
                '<feComposite in="d" in2="m" operator="in"/></filter>')
# Washi paper: soft fibrous mottling and a fine grain, both as translucent overlays.
MOTTLE_FILTER = ('<filter id="mottle" x="0" y="0" width="100%" height="100%">'
                 '<feTurbulence type="fractalNoise" baseFrequency="0.011" numOctaves="4" seed="21"/>'
                 '<feColorMatrix values="0 0 0 0 .45  0 0 0 0 .40  0 0 0 0 .30  0 0 0 .16 -.02"/></filter>')
GRAIN_FILTER = ('<filter id="grain" x="0" y="0" width="100%" height="100%">'
                '<feTurbulence type="fractalNoise" baseFrequency="0.85" numOctaves="3" seed="7" stitchTiles="stitch"/>'
                '<feColorMatrix values="0 0 0 0 0  0 0 0 0 0  0 0 0 0 0  0 0 0 0.075 0"/></filter>')

# The cursive "S" on the 1024 canvas, as chained cubic Béziers, and the blue full stop after it.
S_PATH = [(676, 322),
          ((622, 232), (432, 226), (404, 334)),
          ((376, 440), (520, 474), (590, 520)),
          ((680, 582), (694, 700), (574, 752)),
          ((460, 800), (330, 762), (304, 694))]
S_WIDTH = 92
DOT = (770, 744, 38.6)
RULES_Y = [256, 384, 512, 640, 768]


def cubic(p0, p1, p2, p3, t):
    u = 1 - t
    return (u ** 3 * p0[0] + 3 * u * u * t * p1[0] + 3 * u * t * t * p2[0] + t ** 3 * p3[0],
            u ** 3 * p0[1] + 3 * u * u * t * p1[1] + 3 * u * t * t * p2[1] + t ** 3 * p3[1])


def points(path, step=2.0):
    """Evenly spaced points along a chain: path = [start, (c1, c2, end), ...]."""
    dense, p = [], path[0]
    for c1, c2, q in path[1:]:
        dense += [cubic(p, c1, c2, q, i / 400) for i in range(400)]
        p = q
    dense.append(p)
    out, acc = [dense[0]], 0.0
    for a, b in zip(dense, dense[1:]):
        acc += math.dist(a, b)
        if acc >= step:
            out.append(b)
            acc = 0.0
    return out + [dense[-1]]


def nib_stroke(path, width, contrast=0.45, angle=-35, taper_in=0.06, taper_out=0.10, min_w=0.18):
    """Ellipses stamped along the path; the union is the stroke. Ends taper like a lifted pen."""
    pts = points(path)
    total = sum(math.dist(a, b) for a, b in zip(pts, pts[1:]))
    rx, ry = width / 2, width / 2 * (1 - contrast)
    out, s = [], 0.0
    for i, (x, y) in enumerate(pts):
        f = s / total
        k = 1.0
        if f < taper_in:
            k = min_w + (1 - min_w) * math.sin(f / taper_in * math.pi / 2)
        elif f > 1 - taper_out:
            k = min_w + (1 - min_w) * math.sin((1 - f) / taper_out * math.pi / 2)
        out.append(f'<ellipse cx="{x:.1f}" cy="{y:.1f}" rx="{rx * k:.1f}" ry="{ry * k:.1f}" '
                   f'transform="rotate({angle} {x:.1f} {y:.1f})"/>')
        if i + 1 < len(pts):
            s += math.dist((x, y), pts[i + 1])
    return "".join(out)


def svg(body, size=1024):
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {size} {size}" '
            f'width="{size}" height="{size}">{body}</svg>\n')


def rules(color=RULE, opacity=1.0, ys=RULES_Y, x0=0, x1=1024, h=10):
    return "".join(f'<rect x="{x0}" y="{y - h / 2}" width="{x1 - x0}" height="{h}" fill="{color}" '
                   f'fill-opacity="{opacity}"/>' for y in ys)


def s_mark():
    return f'<g fill="{INK}">{nib_stroke(S_PATH, S_WIDTH)}</g>'


def dot(grow=0):
    x, y, r = DOT
    return f'<circle cx="{x}" cy="{y}" r="{r + grow}" fill="{BLUE}"/>'


def brush_s():
    """The app icon's S, painted with a brush: wider, softer nib contrast, rough dry-brush edges."""
    path = [(S_PATH[0][0] + 8, S_PATH[0][1] - 10)] + S_PATH[1:]
    stroke = nib_stroke(path, 118, contrast=.22, taper_in=.04, taper_out=.16, min_w=.06)
    return f'<defs>{BRUSH_FILTER}</defs><g filter="url(#brush)" fill="{INK}">{stroke}</g>'


def washi_texture():
    """The paper layer on top of the icon's washi fill: a soft vignette, mottling and grain."""
    vignette = ('<radialGradient id="vig" cx="50%" cy="38%" r="75%">'
                '<stop offset="0" stop-color="#fff" stop-opacity=".35"/>'
                '<stop offset="1" stop-color="#8c887a" stop-opacity=".22"/></radialGradient>')
    return (f'<defs>{vignette}{MOTTLE_FILTER}{GRAIN_FILTER}</defs>'
            '<rect width="1024" height="1024" fill="url(#vig)"/>'
            '<rect width="1024" height="1024" filter="url(#mottle)"/>'
            '<rect width="1024" height="1024" filter="url(#grain)"/>')


def badge():
    """Bridge badge: a PDF sheet with a folded corner and a blue arrow (hand-off to Preview)."""
    x, y, w, h, f = 600, 556, 300, 372, 86
    return (f'<path d="M{x + 18} {y} H{x + w - f} L{x + w} {y + f} V{y + h - 18} Q{x + w} {y + h} '
            f'{x + w - 18} {y + h} H{x + 18} Q{x} {y + h} {x} {y + h - 18} V{y + 18} Q{x} {y} {x + 18} {y} Z" '
            f'fill="{SHEET}"/>'
            f'<path d="M{x + w - f} {y} V{y + f - 14} Q{x + w - f} {y + f} {x + w - f + 14} {y + f} H{x + w} Z" '
            f'fill="#DCDBD5"/>'
            f'<rect x="{x + 40}" y="{y + 120}" width="140" height="16" rx="8" fill="#BDBCB6"/>'
            f'<rect x="{x + 40}" y="{y + 160}" width="110" height="16" rx="8" fill="#BDBCB6"/>'
            f'<g transform="translate({x + w / 2 + 6} {y + h - 118})" stroke="{BLUE}" stroke-width="34" '
            f'stroke-linecap="round" stroke-linejoin="round" fill="none">'
            f'<path d="M-62 62 L58 -58"/><path d="M-6 -62 H62 V6"/></g>')


# --- Document icons ---------------------------------------------------------------------------
# A page with a folded corner on the 1024 canvas, like the macOS document template.
PX0, PY0, PX1, PY1, FOLD, R = 164, 60, 860, 964, 196, 36


def page(label, content, small, fill=PAPER_LIGHT):
    shadow = ('<filter id="sh" x="-10%" y="-10%" width="120%" height="120%">'
              '<feDropShadow dx="0" dy="8" stdDeviation="10" flood-opacity=".22"/></filter>')
    outline = (f'M{PX0 + R} {PY0} H{PX1 - FOLD} L{PX1} {PY0 + FOLD} V{PY1 - R} Q{PX1} {PY1} {PX1 - R} {PY1} '
               f'H{PX0 + R} Q{PX0} {PY1} {PX0} {PY1 - R} V{PY0 + R} Q{PX0} {PY0} {PX0 + R} {PY0} Z')
    fold = (f'M{PX1 - FOLD} {PY0} V{PY0 + FOLD - 30} Q{PX1 - FOLD} {PY0 + FOLD} {PX1 - FOLD + 30} {PY0 + FOLD} '
            f'H{PX1} Z')
    body = (f'<defs>{shadow}<clipPath id="pg"><path d="{outline}"/></clipPath></defs>'
            f'<path d="{outline}" fill="{fill}" filter="url(#sh)"/>'
            f'<g clip-path="url(#pg)">{content}</g>'
            f'<path d="{outline}" fill="none" stroke="#000" stroke-opacity=".16" stroke-width="{10 if small else 4}"/>'
            f'<path d="{fold}" fill="#D9D8D1"/>')
    if label and not small:
        body += (f'<text x="512" y="{PY1 - 74}" text-anchor="middle" font-family="-apple-system, \'SF Pro Text\', '
                 f'\'Helvetica Neue\', sans-serif" font-weight="700" font-size="104" letter-spacing="12" '
                 f'fill="#77766F">{label}</text>')
    return svg(body)


def doc_note(small):
    """A ruled page with the S mark: the notebook itself."""
    ys = [360, 520, 680] if small else [300, 400, 500, 600, 700]
    content = rules(opacity=.16 if small else .13, ys=ys, h=16 if small else 8)
    scale = 0.86 if small else 0.64
    cy = 540 if small else 470
    content += (f'<g transform="translate(512 {cy}) scale({scale}) translate(-540 -512)">'
                f'{s_mark()}{dot()}</g>')
    return page(None if small else "NOTE", content, small)


def doc_mark(small):
    """Grey type lines (the PDF) with a handwritten loop and underline on top."""
    lines = [(300, 520), (380, 470), (460, 540), (540, 390), (620, 500), (700, 450)]
    if small:
        lines = [(330, 500), (480, 420), (630, 470)]
    h = 40 if small else 26
    content = "".join(f'<rect x="250" y="{y - h / 2}" width="{w}" height="{h}" rx="{h / 2}" fill="#C4C3BC"/>'
                      for y, w in lines)
    if small:
        under = [(250, 560), ((380, 548), (520, 550), (640, 562))]
        content += f'<g fill="{INK}">{nib_stroke(under, 64, taper_out=0.04)}</g>'
        content += f'<circle cx="716" cy="564" r="38" fill="{BLUE}"/>'
    else:
        # A word circled on the third line and the fifth line underlined, ending in the blue full stop.
        loop = [(520, 420), ((610, 436), (600, 506), (420, 508)), ((250, 512), (214, 470), (290, 432)),
                ((350, 402), (480, 404), (566, 446))]
        under = [(250, 662), ((400, 648), (580, 650), (712, 664))]
        content += f'<g fill="{INK}">{nib_stroke(loop, 30)}{nib_stroke(under, 34, taper_out=0.05)}</g>'
        content += f'<circle cx="758" cy="666" r="19" fill="{BLUE}"/>'
    return page(None if small else "MARK", content, small, fill=SHEET)


def write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as fh:
        fh.write(text)


if __name__ == "__main__":
    for app in ("Viewer", "Bridge", "ViewerIOS"):
        assets = os.path.join(ROOT, app, "AppIcon.icon", "Assets")
        write(os.path.join(assets, "dot.svg"), svg(dot(grow=4)))
        if app == "Bridge":
            write(os.path.join(assets, "badge.svg"), svg(badge()))
    # Brush and paper layers: rendered to stroke.png and paper.png by render.sh.
    write(os.path.join(BUILD, "icon-stroke.svg"), svg(brush_s()))
    write(os.path.join(BUILD, "icon-paper.svg"), svg(washi_texture()))
    for small in (False, True):
        suffix = "-small" if small else ""
        write(os.path.join(BUILD, f"note{suffix}.svg"), doc_note(small))
        write(os.path.join(BUILD, f"mark{suffix}.svg"), doc_mark(small))
