"""Icon concepts explored for the app name: Sumi (chosen, see Artwork/sumi/), Remora and Quire.

Exploration only: writes 1024x1024 full-bleed SVGs to Artwork/concepts/build/svg/ (the system
applies the rounded mask). Strokes reuse nib_stroke() from Artwork/artwork.py so the ink matches the
current icon. Render with render.sh.
"""
import math
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
from artwork import (nib_stroke, BLUE, INK, PAPER, S_PATH, S_WIDTH, DOT,  # noqa: E402
                     WASHI, BRUSH_FILTER, MOTTLE_FILTER)

OUT = os.path.join(HERE, "build", "svg")

CREAM = "#F2EFE6"
NAVY_TOP, NAVY_BOT = "#26406E", "#152541"
INKBG_TOP, INKBG_BOT = "#2A2A28", "#121211"
BLUE_LIGHT = "#5D86D6"
SERIF = "Didot, 'Bodoni 72', Baskerville, Georgia, serif"

ICONS = []  # (id, name, concept, colourway)


# --- Building blocks ---------------------------------------------------------------------------

def doc(body, defs=""):
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024">'
            f'<defs>{defs}</defs>{body}</svg>\n')


GRAIN = ('<filter id="grain" x="0" y="0" width="100%" height="100%">'
         '<feTurbulence type="fractalNoise" baseFrequency="0.85" numOctaves="3" seed="7" stitchTiles="stitch"/>'
         '<feColorMatrix values="0 0 0 0 0  0 0 0 0 0  0 0 0 0 0  0 0 0 0.075 0"/></filter>')
SHADOW = ('<filter id="shadow" x="-30%" y="-30%" width="160%" height="160%">'
          '<feDropShadow dx="0" dy="14" stdDeviation="18" flood-color="#000" flood-opacity=".28"/></filter>'
          '<filter id="soft" x="-30%" y="-30%" width="160%" height="160%">'
          '<feDropShadow dx="0" dy="6" stdDeviation="8" flood-color="#000" flood-opacity=".18"/></filter>')


def paper_bg(ruled=True, rule_ys=(256, 384, 512, 640, 768), tone=PAPER):
    defs = (GRAIN + SHADOW +
            '<radialGradient id="vig" cx="50%" cy="38%" r="75%">'
            '<stop offset="0" stop-color="#fff" stop-opacity=".35"/>'
            '<stop offset="1" stop-color="#8c887a" stop-opacity=".22"/></radialGradient>')
    body = f'<rect width="1024" height="1024" fill="{tone}"/><rect width="1024" height="1024" fill="url(#vig)"/>'
    if ruled:
        body += "".join(f'<rect x="0" y="{y - 4}" width="1024" height="8" fill="#1E1E19" fill-opacity=".11"/>'
                        for y in rule_ys)
    return defs, body


def dark_bg(top, bot, glow="#ffffff", glow_op=.10):
    defs = (GRAIN + SHADOW +
            f'<linearGradient id="bg" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="{top}"/>'
            f'<stop offset="1" stop-color="{bot}"/></linearGradient>'
            f'<radialGradient id="glow" cx="50%" cy="30%" r="70%"><stop offset="0" stop-color="{glow}" '
            f'stop-opacity="{glow_op}"/><stop offset="1" stop-color="{glow}" stop-opacity="0"/></radialGradient>')
    return defs, '<rect width="1024" height="1024" fill="url(#bg)"/><rect width="1024" height="1024" fill="url(#glow)"/>'


def grain():
    return '<rect width="1024" height="1024" filter="url(#grain)"/>'


def ink(paths, width, color=INK, **kw):
    return f'<g fill="{color}">' + "".join(nib_stroke(p, width, **kw) for p in paths) + "</g>"


def dot(x, y, r, color=BLUE):
    return f'<circle cx="{x}" cy="{y}" r="{r}" fill="{color}"/>'


def emit(ident, name, concept, colourway, svg_text):
    os.makedirs(OUT, exist_ok=True)
    with open(os.path.join(OUT, f"{ident}.svg"), "w") as fh:
        fh.write(svg_text)
    ICONS.append((ident, name, concept, colourway))


def colourways(ident, name, concept, art, ways):
    """art(way) -> (defs, body); ways = list of (suffix, label, bg)."""
    for suffix, label, bg in ways:
        bdefs, bbody = bg()
        adefs, abody = art(suffix)
        emit(f"{ident}-{suffix}", name, concept, label, doc(bbody + abody + grain(), bdefs + adefs))


PAPER_WAY = ("paper", "Paper", lambda: paper_bg())
PLAIN_WAY = ("plain", "Paper, unruled", lambda: paper_bg(ruled=False))
NAVY_WAY = ("navy", "Deep blue", lambda: dark_bg(NAVY_TOP, NAVY_BOT))
INK_WAY = ("ink", "Ink black", lambda: dark_bg(INKBG_TOP, INKBG_BOT, glow_op=.07))


def fg(way):
    """Foreground ink and accent for a colourway."""
    return (CREAM, BLUE_LIGHT) if way in ("navy", "ink") else (INK, BLUE)


# --- Remora ------------------------------------------------------------------------------------
# A remora in profile facing right: flat head with the sucking disc on top, protruding lower jaw,
# long dorsal and anal fins, slender body, forked tail. Designed on the 1024 canvas.
FISH = ("M890 520 "
        "C870 486 820 462 750 450 "          # snout up to the flat head (sucking disc on top)
        "C640 432 520 440 420 462 "          # back
        "C340 480 270 500 214 510 "          # taper to the caudal peduncle
        "C190 470 160 420 120 384 "          # upper tail lobe
        "C138 450 150 490 168 524 "          # tail fork
        "C150 560 136 604 118 664 "          # lower tail lobe
        "C158 626 188 578 214 540 "          # caudal peduncle (bottom)
        "C280 552 350 580 430 592 "          # belly
        "C540 608 660 604 760 586 "
        "C820 576 864 560 892 544 "          # lower jaw juts forward
        "C902 538 900 528 890 520 Z")
FINS = ("M452 466 C410 446 340 444 280 476 C300 486 318 494 330 498 Z",      # dorsal: long and low
        "M456 588 C414 610 344 614 284 568 C302 560 320 552 332 546 Z",      # anal, mirrored
        "M712 572 C684 590 650 604 618 612 C640 594 664 580 690 570 Z")      # small pectoral
FISH_EYE = (808, 502)
DISC = (632, 452, 104, 17)  # cx, cy, rx, ry of the sucking disc on the head
FISH_T = "translate(512 540) rotate(-14) scale(1.1) translate(-505 -516)"


def fish_shape(fill, transform=""):
    return (f'<g fill="{fill}" transform="{transform}"><path d="{FISH}"/>'
            + "".join(f'<path d="{f}"/>' for f in FINS) + '</g>')


def disc_lines(color, opacity):
    """The sucking disc: a striped oval on top of the head, plus a gill line."""
    cx, cy, rx, ry = DISC
    ridges = "".join(f'<path d="M{cx - rx + 18 + i * 18:.0f} {cy - ry + 5} v{2 * ry - 10}"/>' for i in range(11))
    return (f'<g fill="none" stroke="{color}" stroke-opacity="{opacity}" stroke-linecap="round">'
            f'<ellipse cx="{cx}" cy="{cy}" rx="{rx}" ry="{ry}" stroke-width="7"/>'
            f'<g stroke-width="5">{ridges}</g>'
            f'<path d="M742 474 C724 504 722 540 736 576" stroke-width="9"/></g>')


# Calligraphic fish: the back and belly as nib strokes meeting at the snout, a gill and the tail.
FISH_BACK = [(884, 514), ((800, 448), (620, 426), (470, 448)), ((380, 462), (300, 474), (222, 496)),
             ((190, 450), (160, 404), (126, 370))]
FISH_BELLY = [(880, 540), ((780, 600), (600, 610), (470, 590)), ((380, 576), (300, 556), (222, 540)),
              ((190, 586), (160, 622), (126, 662))]
FISH_GILL = [(744, 474), ((714, 510), (716, 548), (740, 582))]
FISH_FIN = [(420, 456), ((390, 420), (330, 414), (286, 446))]


def remora_calligraphic(way):
    c, acc = fg(way)
    return "", (f'<g transform="{FISH_T}">{ink([FISH_BACK, FISH_BELLY], 50, c, taper_in=.02, taper_out=.12)}'
                f'{ink([FISH_GILL, FISH_FIN], 26, c)}{disc_lines(c, .6)}{dot(*FISH_EYE, 20, acc)}</g>')


def remora_silhouette(way):
    c, acc = fg(way)
    eye_bg = "#152541" if way == "navy" else ("#121211" if way == "ink" else PAPER)
    return "", (f'<g filter="url(#soft)"><g transform="{FISH_T}">{fish_shape(c)}'
                f'{disc_lines(eye_bg, .5)}{dot(*FISH_EYE, 19, acc)}</g></g>')


def remora_paper_fish(way):
    """A fish cut from a ruled notebook page, with a line of handwriting on it."""
    defs = f'<clipPath id="fishclip"><path d="{FISH}"/></clipPath>'
    rules_ = "".join(f'<rect x="100" y="{y}" width="820" height="5" fill="#1E1E19" fill-opacity=".14"/>'
                     for y in (480, 532, 584))
    script = [(300, 520), ((330, 488), (362, 490), (372, 516)), ((382, 540), (414, 536), (434, 504)),
              ((454, 474), (480, 508), (500, 520)), ((540, 536), (580, 494), (622, 514))]
    body = (f'<g filter="url(#shadow)"><g transform="{FISH_T}">{fish_shape(CREAM)}</g></g>'
            f'<g transform="{FISH_T}"><g clip-path="url(#fishclip)">{rules_}{ink([script], 16, INK, contrast=.3)}</g>'
            f'{disc_lines("#1E1E19", .3)}{dot(*FISH_EYE, 19, BLUE)}</g>')
    return defs, body


def remora_companion(way):
    """A notebook sheet sailing above with a small remora riding just beneath its edge."""
    c, acc = fg(way)
    sheet = ('<g transform="rotate(-8 512 330)" filter="url(#shadow)">'
             '<rect x="150" y="150" width="724" height="380" rx="34" fill="#F7F5EF"/>'
             + "".join(f'<rect x="210" y="{y}" width="604" height="7" rx="3.5" fill="#1E1E19" fill-opacity=".13"/>'
                       for y in (240, 318, 396, 474))
             + ink([[(232, 300), ((300, 250), (380, 270), (360, 300)), ((340, 330), (420, 330), (470, 290)),
                     ((520, 250), (560, 300), (600, 286))]], 22, INK) + dot(632, 288, 12) + '</g>')
    fish = (f'<g transform="translate(470 690) rotate(-8) scale(.62) translate(-505 -516)" filter="url(#soft)">'
            f'{fish_shape(c)}{dot(*FISH_EYE, 22, acc)}</g>')
    return "", sheet + fish


def remora_porthole(way):
    """A deep-blue porthole on the page with the fish swimming out of it."""
    defs = ('<clipPath id="hole"><circle cx="512" cy="512" r="300"/></clipPath>'
            '<linearGradient id="water" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#2F4C82"/>'
            '<stop offset="1" stop-color="#172848"/></linearGradient>')
    hole = ('<circle cx="512" cy="512" r="300" fill="url(#water)" filter="url(#shadow)"/>'
            '<g clip-path="url(#hole)" fill="#fff" fill-opacity=".06">'
            + "".join(f'<rect x="200" y="{y}" width="624" height="8"/>' for y in (384, 512, 640)) + '</g>')
    fish = (f'<g filter="url(#soft)"><g transform="{FISH_T}">{fish_shape(CREAM)}'
            f'{disc_lines("#172848", .45)}{dot(*FISH_EYE, 19, BLUE)}</g></g>')
    return defs, hole + fish


def remora_monogram(way):
    c, acc = fg(way)
    stem = [(452, 268), ((446, 420), (430, 600), (404, 760))]
    bowl = [(330, 320), ((440, 228), (700, 220), (700, 380)), ((700, 500), (560, 528), (450, 512)),
            ((560, 548), (600, 700), (720, 756))]
    return "", ink([stem], 84, c) + ink([bowl], 84, c, taper_in=.08) + dot(800, 744, 38.6, acc)


def remora_type(way):
    c, acc = fg(way)
    return "", (f'<text x="488" y="770" text-anchor="middle" font-family="{SERIF}" font-size="700" '
                f'fill="{c}">R</text>{dot(800, 744, 38.6, acc)}')


# --- Quire -------------------------------------------------------------------------------------

def quire_monogram(way):
    c, acc = fg(way)
    bowl = [(636, 300), ((480, 220), (290, 330), (290, 510)), ((290, 690), (430, 780), (560, 756)),
            ((720, 726), (780, 560), (740, 420)), ((716, 334), (676, 300), (606, 290))]
    tail = [(470, 648), ((560, 700), (640, 820), (790, 800))]
    return "", ink([bowl], 80, c, taper_in=.09, taper_out=.10) + ink([tail], 76, c, taper_in=.15) + dot(850, 790, 36, acc)


def quire_type(way):
    c, acc = fg(way)
    return "", (f'<text x="500" y="760" text-anchor="middle" font-family="{SERIF}" font-size="700" '
                f'fill="{c}">Q</text>{dot(820, 742, 36, acc)}')


def quire_open(way):
    """An open quire from above: two page spreads, a sewn gutter, handwriting on the left page."""
    c, acc = fg(way)
    edge = "#1E1E19"
    out = '<g filter="url(#shadow)">'
    for i, tone in enumerate(("#D9D6CC", "#E6E3DA", "#FAF8F3")):
        d = (2 - i) * 14
        out += (f'<path d="M{132 - d * .3} {290 + d} Q330 {236 + d} 512 {292 + d} Q694 {236 + d} {892 + d * .3} {290 + d} '
                f'L{892 + d * .3} {762 + d} Q694 {708 + d} 512 {764 + d} Q330 {708 + d} {132 - d * .3} {762 + d} Z" '
                f'fill="{tone}"/>')
    out += '</g>'
    gutter = ('<linearGradient id="gut" x1="0" x2="1"><stop offset="0" stop-color="#000" stop-opacity="0"/>'
              '<stop offset=".5" stop-color="#000" stop-opacity=".16"/><stop offset="1" stop-color="#000" '
              'stop-opacity="0"/></linearGradient>')
    out += '<rect x="452" y="290" width="120" height="476" fill="url(#gut)"/>'
    for side in (-1, 1):
        for k in range(4):
            y = 380 + k * 86
            x0, x1 = 512 + side * 60, 512 + side * 330
            out += (f'<path d="M{x0} {y} Q{(x0 + x1) / 2} {y - 22} {x1} {y - 6}" stroke="{edge}" stroke-opacity=".13" '
                    f'stroke-width="6" fill="none" stroke-linecap="round"/>')
    out += ink([[(200, 360), ((240, 320), (280, 330), (276, 360)), ((272, 392), (320, 388), (350, 350)),
                 ((380, 312), (400, 360), (430, 356))]], 20, INK)
    out += f'<g stroke="{BLUE}" stroke-width="12" stroke-linecap="round">' + "".join(
        f'<path d="M512 {y} v34"/>' for y in (330, 430, 530, 630)) + '</g>'
    return gutter, out


def quire_stitched(way):
    """A Q sewn into the page with a running stitch; the tail is the loose blue thread and needle."""
    c, acc = fg(way)
    r, cx, cy, n = 240, 500, 490, 16
    stitches, holes = "", ""
    for i in range(n):
        a0 = (i / n) * 2 * math.pi - math.pi / 2 + .06
        a1 = a0 + 2 * math.pi / n * .58
        p = lambda a: (cx + r * math.cos(a), cy + r * math.sin(a))
        (x0, y0), (x1, y1) = p(a0), p(a1)
        stitches += f'<path d="M{x0:.1f} {y0:.1f} A{r} {r} 0 0 1 {x1:.1f} {y1:.1f}"/>'
        for hx, hy in (p(a0 - .05), p(a1 + .05)):
            holes += f'<circle cx="{hx:.1f}" cy="{hy:.1f}" r="7"/>'
    hole_c = "#000" if way in ("paper", "plain") else "#000"
    body = (f'<g fill="{hole_c}" fill-opacity=".22">{holes}</g>'
            f'<g fill="none" stroke="{c}" stroke-width="30" stroke-linecap="round" filter="url(#soft)">{stitches}</g>'
            f'<path d="M640 650 C690 700 720 780 800 800" fill="none" stroke="{acc}" stroke-width="18" stroke-linecap="round"/>'
            f'<g transform="rotate(18 800 800)"><path d="M800 786 L930 798 Q936 800 930 802 L800 814 Q790 800 800 786 Z" '
            f'fill="#B9BCC2"/><ellipse cx="812" cy="800" rx="9" ry="4" fill="#5c6068"/></g>')
    return "", body


def quire_stack(way):
    """Gathered sheets, slightly fanned, the top one handwritten, a blue thread through the fold."""
    sheets = ""
    for i, ang in enumerate((-12, -6, 0)):
        tone = ("#E3E0D6", "#EEEBE3", "#FAF8F3")[i]
        sheets += (f'<g transform="rotate({ang} 512 760)" filter="url(#soft)">'
                   f'<rect x="232" y="196" width="560" height="640" rx="30" fill="{tone}"/></g>')
    lines = "".join(f'<rect x="292" y="{y}" width="440" height="7" rx="3.5" fill="#1E1E19" fill-opacity=".12"/>'
                    for y in (340, 430, 520, 610, 700))
    q = ink([[(560, 330), ((470, 300), (380, 360), (384, 450)), ((388, 540), (470, 580), (540, 560)),
              ((620, 536), (640, 440), (610, 386)), ((590, 350), (560, 334), (520, 334))],
             ], 40, INK) + ink([[(500, 500), ((540, 540), (600, 600), (680, 600))]], 38, INK) + dot(716, 600, 18)
    spine = (f'<g stroke="{BLUE}" stroke-width="10" stroke-linecap="round">'
             + "".join(f'<path d="M232 {y} h-22"/>' for y in (300, 516, 732)) + '</g>')
    return "", sheets + lines + q + spine


def quire_ribbon(way):
    """A closed notebook whose bookmark ribbon forms the tail of a Q."""
    c, acc = fg(way)
    cover = INK if way in ("paper", "plain") else CREAM
    page = PAPER if way in ("paper", "plain") else "#1A2B49" if way == "navy" else "#1A1A19"
    book = (f'<g filter="url(#shadow)"><rect x="262" y="176" width="500" height="620" rx="40" fill="{cover}"/>'
            f'<rect x="742" y="200" width="26" height="572" rx="8" fill="{cover}" fill-opacity=".7"/>'
            f'<rect x="300" y="176" width="22" height="620" fill="#000" fill-opacity=".12"/></g>')
    ring = (f'<circle cx="530" cy="470" r="150" fill="none" stroke="{page}" stroke-width="40"/>')
    ribbon = (f'<g transform="rotate(-24 622 590)" filter="url(#soft)"><path d="M594 560 h56 v330 l-28 -38 l-28 38 Z" '
              f'fill="{acc}"/><rect x="594" y="560" width="56" height="40" fill="#000" fill-opacity=".15"/></g>')
    return "", book + ring + ribbon


# --- Pen-nib concepts ---------------------------------------------------------------------------
# A fountain-pen nib pointing right, centred on the origin; the breather hole is the blue dot.
NIB = ("M360 0 C260 -26 120 -98 10 -146 C-30 -162 -70 -166 -110 -158 "
       "L-110 158 C-70 166 -30 162 10 146 C120 98 260 26 360 0 Z")
NIB_TAIL = ("M-104 -64 C-150 -44 -180 -34 -204 -34 C-232 -96 -262 -146 -316 -176 "
            "C-292 -96 -282 -44 -282 0 C-282 44 -292 96 -316 176 C-262 146 -232 96 -204 34 "
            "C-180 34 -150 44 -104 64 Z")


def nib(fill, cut, acc, tail=False):
    shape = f'<path d="{NIB}" fill="{fill}"/>' + (f'<path d="{NIB_TAIL}" fill="{fill}"/>' if tail else "")
    engraving = (f'<g fill="none" stroke="{cut}" stroke-opacity=".35" stroke-width="7" stroke-linecap="round">'
                 '<path d="M-60 -120 C-20 -60 -20 60 -60 120"/><path d="M-84 -128 C-44 -64 -44 64 -84 128"/></g>')
    slit = f'<path d="M352 0 H70" stroke="{cut}" stroke-width="10" stroke-linecap="round"/>'
    return shape + engraving + slit + dot(50, 0, 26, acc)


def bg_of(way):
    return {"navy": "#1B2D50", "ink": "#1A1A19"}.get(way, PAPER)


def remora_nibfish(way):
    """A fountain-pen nib that grew a tail: the pen that rides along with your notes."""
    c, acc = fg(way)
    return "", (f'<g filter="url(#soft)"><g transform="translate(500 520) rotate(-16) scale(1.12) translate(-22 0)">'
                f'{nib(c, bg_of(way), acc, tail=True)}</g></g>')


def quire_pen(way):
    """A Q whose tail is a fountain-pen nib."""
    c, acc = fg(way)
    ring = f'<circle cx="466" cy="456" r="228" fill="none" stroke="{c}" stroke-width="66"/>'
    pen = (f'<g transform="translate(676 690) rotate(42) scale(.74)">{nib(c, bg_of(way), acc)}</g>')
    return "", f'<g filter="url(#soft)">{ring}{pen}</g>'


def swash(letter, x, y, size, dx, dy):
    def art(way):
        c, acc = fg(way)
        return "", (f'<text x="{x}" y="{y}" text-anchor="middle" font-family="\'Snell Roundhand\', cursive" '
                    f'font-weight="700" font-size="{size}" fill="{c}">{letter}</text>{dot(dx, dy, 34, acc)}')
    return art


# --- Sumi --------------------------------------------------------------------------------------
# Sumi is the ink of Japanese calligraphy. Today's S stays; the concepts move it from pen to brush
# and add the ink-painting vocabulary (ensō, seal, ink drop, wash). The blue is indigo (ai-iro).
BRUSH = (BRUSH_FILTER +
         '<filter id="rough" x="-10%" y="-10%" width="120%" height="120%">'
         '<feTurbulence type="fractalNoise" baseFrequency="0.04" numOctaves="3" seed="5" result="n"/>'
         '<feDisplacementMap in="SourceGraphic" in2="n" scale="10" xChannelSelector="R" yChannelSelector="G"/></filter>')


def washi_bg():
    defs, body = paper_bg(ruled=False, tone=WASHI)
    defs += MOTTLE_FILTER
    return defs + BRUSH, body + '<rect width="1024" height="1024" filter="url(#mottle)"/>'


def sumi_dark_bg():
    defs, body = dark_bg("#262624", "#0F0F0E", glow_op=.06)
    # A faint ink wash pooled across the lower half.
    defs += ('<radialGradient id="wash" cx="40%" cy="78%" r="60%"><stop offset="0" stop-color="#5a5852" '
             'stop-opacity=".35"/><stop offset="1" stop-color="#5a5852" stop-opacity="0"/></radialGradient>')
    return defs + BRUSH, body + '<rect width="1024" height="1024" fill="url(#wash)"/>'


def indigo_bg():
    defs, body = dark_bg("#24406F", "#13213C")
    return defs + BRUSH, body


WASHI_WAY = ("washi", "Washi paper", washi_bg)
RULED_WAY = ("paper", "Ruled paper (today)", lambda: (lambda d, b: (d + BRUSH, b))(*paper_bg()))
SUMI_WAY = ("ink", "Sumi black", sumi_dark_bg)
INDIGO_WAY = ("navy", "Indigo", indigo_bg)


def arc(cx, cy, r, a0, a1, wobble=()):
    """A circular arc from angle a0 to a1 (degrees, clockwise on screen) as a cubic chain."""
    n = max(1, int(abs(a1 - a0) // 45) + 1)
    step = (a1 - a0) / n
    k = 4 / 3 * math.tan(math.radians(step) / 4)
    rad = [r + (wobble[i % len(wobble)] if wobble else 0) for i in range(n + 1)]
    pt = lambda a, rr: (cx + rr * math.cos(math.radians(a)), cy + rr * math.sin(math.radians(a)))
    path = [pt(a0, rad[0])]
    for i in range(n):
        s, e = a0 + i * step, a0 + (i + 1) * step
        p0, p3 = pt(s, rad[i]), pt(e, rad[i + 1])
        t0 = (-math.sin(math.radians(s)), math.cos(math.radians(s)))
        t1 = (-math.sin(math.radians(e)), math.cos(math.radians(e)))
        c1 = (p0[0] + k * rad[i] * t0[0], p0[1] + k * rad[i] * t0[1])
        c2 = (p3[0] - k * rad[i + 1] * t1[0], p3[1] - k * rad[i + 1] * t1[1])
        path.append((c1, c2, p3))
    return path


def brush(paths, width, color, **kw):
    kw.setdefault("contrast", .22)
    kw.setdefault("taper_out", .22)
    kw.setdefault("min_w", .06)
    return f'<g filter="url(#brush)">{ink(paths, width, color, **kw)}</g>'


def s_today(way):
    c, acc = fg(way)
    return "", ink([S_PATH], S_WIDTH, c) + dot(*DOT, acc)


def s_brush(way):
    c, acc = fg(way)
    path = [(S_PATH[0][0] + 8, S_PATH[0][1] - 10)] + S_PATH[1:]
    return "", brush([path], 118, c, taper_in=.04, taper_out=.16) + dot(*DOT[:2], DOT[2] + 4, acc)


def s_enso(way):
    c, acc = fg(way)
    circle = arc(512, 512, 318, 112, 432 - 26, wobble=(0, 8, -6, 10, -4, 6, 0, -8))
    return "", brush([circle], 92, c, taper_in=.03, taper_out=.30) + dot(512, 512, 40, acc)


def s_enso_s(way):
    c, acc = fg(way)
    circle = arc(512, 512, 336, 118, 432 - 34, wobble=(0, 6, -6, 8, -4, 6, 0, -6))
    s = f'<g transform="translate(512 512) scale(.52) translate(-490 -512)">{ink([S_PATH], S_WIDTH, c)}</g>'
    return "", brush([circle], 64, c, taper_in=.03, taper_out=.30) + s + dot(706, 674, 22, acc)


def s_seal(way):
    """The brush S with a square indigo seal (hanko) carrying 墨, 'ink', in place of the full stop."""
    c, acc = fg(way)
    path = [(S_PATH[0][0] + 8, S_PATH[0][1] - 10)] + S_PATH[1:]
    seal_fg = WASHI if way != "navy" else "#13213C"
    seal_bg = acc if way != "navy" else CREAM
    seal = (f'<g transform="translate(694 688) rotate(-3) scale(1.12)" filter="url(#rough)">'
            f'<rect width="150" height="150" rx="14" fill="{seal_bg}"/>'
            f'<rect x="12" y="12" width="126" height="126" rx="8" fill="none" stroke="{seal_fg}" stroke-width="6"/>'
            f'<text x="75" y="113" text-anchor="middle" font-family="\'Hiragino Mincho ProN\', \'Songti SC\', serif" '
            f'font-weight="600" font-size="104" fill="{seal_fg}">墨</text></g>')
    return "", (f'<g transform="translate(-40 -40)">{brush([path], 112, c, taper_in=.04, taper_out=.16)}</g>' + seal)


def s_drop(way):
    """A single drop of sumi with the S reversed out of it."""
    drop_c = INK if way in ("paper", "washi") else CREAM
    s_c = WASHI if way in ("paper", "washi") else ("#13213C" if way == "navy" else "#121211")
    _, acc = fg(way)
    drop = ('M512 150 C560 260 760 420 760 600 C760 750 650 862 512 862 '
            'C374 862 264 750 264 600 C264 420 464 260 512 150 Z')
    s = (f'<g transform="translate(512 610) scale(.46) translate(-490 -512)">{ink([S_PATH], S_WIDTH + 6, s_c)}</g>')
    shine = f'<path d="M352 560 C352 480 400 400 440 350" stroke="#fff" stroke-opacity=".16" stroke-width="22" fill="none" stroke-linecap="round"/>'
    return "", (f'<g filter="url(#shadow)"><path d="{drop}" fill="{drop_c}"/></g>{shine}{s}'
                f'{dot(632, 730, 20, acc)}')


def s_stone(way):
    """An inkstone (suzuri) from above: the ink pool holds the S."""
    stone = ('<rect x="232" y="132" width="560" height="760" rx="90" fill="#2C2C2A"/>'
             '<rect x="262" y="162" width="500" height="700" rx="70" fill="#3A3A37"/>')
    pool = ('<radialGradient id="pool" cx="50%" cy="40%" r="70%"><stop offset="0" stop-color="#1c1c1b"/>'
            '<stop offset="1" stop-color="#090909"/></radialGradient>')
    well = '<path d="M300 300 C300 210 724 210 724 300 L724 420 C640 470 384 470 300 420 Z" fill="url(#pool)"/>'
    slope = '<rect x="300" y="480" width="424" height="340" rx="40" fill="#454542"/>'
    s = f'<g transform="translate(512 652) scale(.5) translate(-490 -512)">{ink([S_PATH], S_WIDTH, CREAM)}</g>'
    _, acc = fg(way)
    return pool, f'<g filter="url(#shadow)">{stone}</g>{well}{slope}{s}{dot(512, 340, 26, BLUE_LIGHT)}'


def s_wordmark(way):
    """The brush S with a small lowercase 'sumi' set under it: icon as signature."""
    c, acc = fg(way)
    s = f'<g transform="translate(512 450) scale(.74) translate(-490 -512)">{ink([S_PATH], S_WIDTH, c)}</g>'
    word = (f'<text x="512" y="842" text-anchor="middle" font-family="{SERIF}" font-size="118" '
            f'letter-spacing="10" fill="{c}">sumi</text>')
    return "", s + dot(700, 640, 30, acc) + word


# --- Write everything -------------------------------------------------------------------------

if __name__ == "__main__":
    colourways("remora-calligraphic", "Remora", "Calligraphic fish", remora_calligraphic,
               [PAPER_WAY, PLAIN_WAY, NAVY_WAY, INK_WAY])
    colourways("remora-silhouette", "Remora", "Silhouette", remora_silhouette, [PLAIN_WAY, NAVY_WAY, INK_WAY])
    colourways("remora-paperfish", "Remora", "Paper fish", remora_paper_fish, [NAVY_WAY, INK_WAY])
    colourways("remora-companion", "Remora", "Rides along", remora_companion, [NAVY_WAY, INK_WAY])
    colourways("remora-monogram", "Remora", "Script R", remora_monogram, [PAPER_WAY, INK_WAY])
    colourways("remora-type", "Remora", "Serif R", remora_type, [PLAIN_WAY, NAVY_WAY])
    colourways("remora-porthole", "Remora", "Porthole", remora_porthole, [PLAIN_WAY, PAPER_WAY])
    colourways("remora-nibfish", "Remora", "Nib fish", remora_nibfish, [NAVY_WAY, PLAIN_WAY, INK_WAY])
    colourways("remora-swash", "Remora", "Swash R", swash("R", 500, 720, 640, 800, 744), [PLAIN_WAY, NAVY_WAY])
    colourways("sumi-today", "Sumi", "Today's S", s_today, [RULED_WAY, WASHI_WAY, SUMI_WAY, INDIGO_WAY])
    colourways("sumi-brush", "Sumi", "Brush S", s_brush, [WASHI_WAY, SUMI_WAY, INDIGO_WAY])
    colourways("sumi-seal", "Sumi", "Seal", s_seal, [WASHI_WAY, SUMI_WAY, INDIGO_WAY])
    colourways("sumi-enso", "Sumi", "Ensō", s_enso, [WASHI_WAY, SUMI_WAY, INDIGO_WAY])
    colourways("sumi-ensos", "Sumi", "Ensō S", s_enso_s, [WASHI_WAY, SUMI_WAY, INDIGO_WAY])
    colourways("sumi-drop", "Sumi", "Ink drop", s_drop, [WASHI_WAY, INDIGO_WAY])
    colourways("sumi-word", "Sumi", "Signature", s_wordmark, [WASHI_WAY, SUMI_WAY])
    colourways("quire-pen", "Quire", "Pen Q", quire_pen, [NAVY_WAY, PLAIN_WAY, INK_WAY])
    colourways("quire-monogram", "Quire", "Script Q", quire_monogram, [PAPER_WAY, PLAIN_WAY, NAVY_WAY, INK_WAY])
    colourways("quire-type", "Quire", "Serif Q", quire_type, [PLAIN_WAY, NAVY_WAY, INK_WAY])
    colourways("quire-open", "Quire", "Open quire", quire_open, [NAVY_WAY, INK_WAY, PLAIN_WAY])
    colourways("quire-stitched", "Quire", "Stitched Q", quire_stitched, [PLAIN_WAY, NAVY_WAY])
    colourways("quire-stack", "Quire", "Gathered sheets", quire_stack, [NAVY_WAY, INK_WAY])
    colourways("quire-ribbon", "Quire", "Bookmark Q", quire_ribbon, [PLAIN_WAY, NAVY_WAY])
    with open(os.path.join(HERE, "build", "icons.tsv"), "w") as fh:
        fh.writelines("\t".join(row) + "\n" for row in ICONS)
    print(f"wrote {len(ICONS)} icons")
