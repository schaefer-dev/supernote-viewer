"""Contact sheets for the icon concepts: build/sheet-remora.html and build/sheet-quire.html.

Each concept shows every colourway, a size ladder (App Store to Settings size), an App Store search
result, a home-screen row and a wordmark lockup. render.sh screenshots them to PNG.
"""
import html
import os
from collections import OrderedDict

HERE = os.path.dirname(os.path.abspath(__file__))
BUILD = os.path.join(HERE, "build")

ABOUT = {
    "Calligraphic fish": "The remora drawn with the same broad-nib pen as today's S, the disc on its head and a blue eye.",
    "Silhouette": "A solid, simple remora shape with the striped sucking disc on its head. The most legible at small sizes.",
    "Paper fish": "The fish cut from a ruled notebook page, with a line of handwriting on it.",
    "Rides along": "A notebook page with a small remora riding beneath it: the companion story.",
    "Porthole": "A deep-blue porthole set into the page, with the fish swimming out of it.",
    "Nib fish": "A fountain-pen nib that grew a tail. The breather hole is the blue eye.",
    "Today's S": "The current icon, unchanged. Sumi works without a redesign; shown on ruled paper, washi, sumi black and indigo.",
    "Brush S": "The same S, painted with a brush instead of a pen: rough edges, a hint of dry brush, the indigo full stop.",
    "Seal": "The brush S signed with a square indigo seal (hanko) reading 墨, 'ink', in place of the full stop.",
    "Ensō": "The zen brush circle with the indigo dot at its centre. Reads instantly as ink painting.",
    "Ensō S": "Today's S inside a brushed ensō circle.",
    "Ink drop": "A single drop of sumi with today's S reversed out of it.",
    "Signature": "The S with a small lowercase wordmark, like a signed sheet.",
    "Script R": "Today's icon with the letter changed: a broad-nib R and the blue full stop.",
    "Swash R": "A formal copperplate R with the blue full stop.",
    "Serif R": "A high-contrast Didone R with the blue full stop. Quiet and editorial.",
    "Script Q": "Today's icon with the letter changed: a broad-nib Q whose tail lifts off the page.",
    "Serif Q": "A Didone Q with its sweeping tail, plus the blue full stop. Bookish and calm.",
    "Pen Q": "A Q whose tail is a fountain-pen nib, with the blue breather hole.",
    "Open quire": "An open booklet seen from above, with blue stitches down the sewn gutter and handwriting on the left page.",
    "Gathered sheets": "A few gathered, slightly fanned sheets, with a handwritten Q on the top one.",
    "Stitched Q": "A Q sewn into the page with a running stitch. The tail is the loose blue thread and its needle.",
    "Bookmark Q": "A closed notebook with a Q on the cover whose tail is the blue bookmark ribbon.",
}
SUBTITLE = {"Sumi": "View & search your handwriting", "Remora": "Notebook & PDF mark viewer", "Quire": "View & search your handwriting"}

CSS = """
:root { --bg:#F4F3EF; --card:#fff; --ink:#1b1b1a; --muted:#6f6d66; --line:#e3e1da; }
* { box-sizing:border-box; margin:0; }
body { background:var(--bg); color:var(--ink); font:16px/1.45 -apple-system, 'SF Pro Text', system-ui, sans-serif;
       padding:56px 64px; width:1600px; }
h1 { font:400 54px/1.1 Didot, 'Bodoni 72', serif; letter-spacing:.2px; }
h1 small { display:block; font:500 17px -apple-system, system-ui; color:var(--muted); margin-top:12px; letter-spacing:0; }
.lockups { display:flex; gap:28px; margin:36px 0 44px; flex-wrap:wrap; }
.lockup { display:flex; align-items:center; gap:22px; padding:26px 34px; border-radius:22px; }
.lockup img { width:96px; height:96px; border-radius:22.4%; box-shadow:0 6px 18px rgba(0,0,0,.18); }
.lockup .w { font:400 52px/1 Didot, 'Bodoni 72', serif; }
.lockup .s { font:600 13px/1 -apple-system, system-ui; letter-spacing:3px; text-transform:uppercase; margin-top:10px; opacity:.6; }
.lockup.light { background:#fff; } .lockup.dark { background:#141413; color:#F2EFE6; }
.lockup.navy { background:#1B2D50; color:#F2EFE6; }
.card { background:var(--card); border-radius:26px; padding:32px 36px; margin-bottom:28px;
        box-shadow:0 1px 0 var(--line), 0 10px 30px rgba(0,0,0,.04); }
.head { display:flex; align-items:baseline; gap:16px; margin-bottom:20px; }
.head h2 { font:600 24px -apple-system, system-ui; }
.head p { color:var(--muted); }
.row { display:flex; gap:44px; align-items:flex-start; }
.ways { display:flex; gap:22px; }
.way { text-align:center; font-size:13px; color:var(--muted); }
.way img { width:176px; height:176px; border-radius:22.4%; display:block; margin-bottom:8px;
           box-shadow:0 0 0 1px rgba(0,0,0,.06), 0 8px 22px rgba(0,0,0,.14); }
.side { display:flex; flex-direction:column; gap:18px; margin-left:auto; }
.ladder { display:flex; align-items:flex-end; gap:14px; }
.ladder img { border-radius:22.4%; box-shadow:0 0 0 1px rgba(0,0,0,.06), 0 3px 8px rgba(0,0,0,.12); }
.store { display:flex; align-items:center; gap:14px; width:430px; padding:14px 16px; border-radius:16px; background:#fafaf8;
         box-shadow:0 0 0 1px var(--line); }
.store img { width:64px; height:64px; border-radius:22.4%; box-shadow:0 0 0 1px rgba(0,0,0,.08); }
.store .t { font-weight:600; font-size:16px; } .store .st { color:var(--muted); font-size:14px; }
.store .stars { color:#9a988f; font-size:12px; margin-top:2px; }
.store .get { margin-left:auto; background:#EDEDF0; color:#0A66E4; font-weight:700; border-radius:20px; padding:6px 20px; font-size:15px; }
.home { display:flex; gap:24px; padding:18px 22px 14px; border-radius:18px; width:430px;
        background:linear-gradient(135deg,#4d6a8f,#c99f7e 60%,#e5c3a4); }
.home div { text-align:center; color:#fff; font-size:11.5px; text-shadow:0 1px 2px rgba(0,0,0,.35); }
.home img, .home i { width:60px; height:60px; border-radius:22.4%; display:block; margin-bottom:5px; }
.home i { background:rgba(255,255,255,.55); }
.cap { font-size:12px; color:var(--muted); text-transform:uppercase; letter-spacing:1.4px; margin-bottom:6px; }
"""

BRAND = """
<style>
.brand { display:grid; grid-template-columns: 1.1fr 1fr 1fr; gap:28px; margin-bottom:28px; }
.brand .card { margin:0; }
.sw { display:flex; gap:12px; margin-top:6px; }
.sw div { flex:1; border-radius:14px; height:120px; padding:10px 12px; display:flex; flex-direction:column;
          justify-content:flex-end; font-size:12px; line-height:1.3; box-shadow:0 0 0 1px rgba(0,0,0,.06); }
.sw b { font-size:14px; }
.tag { font:400 30px/1.25 Didot, 'Bodoni 72', serif; margin:4px 0 14px; }
.list { color:var(--muted); line-height:1.9; }
.list b { color:var(--ink); font-weight:600; }
.mark2 { display:flex; align-items:center; gap:26px; margin:10px 0 18px; }
.mark2 .a { font:400 64px/1 Didot, 'Bodoni 72', serif; }
.mark2 .b { font:300 60px/1 -apple-system, 'SF Pro Display', system-ui; letter-spacing:6px; }
.mark2 .a i, .mark2 .b i { color:#2B4C8C; font-style:normal; }
</style>
<div class="brand">
  <div class="card"><div class="cap">Story</div>
    <div class="tag">Your notes, in ink.</div>
    <p class="list">Sumi (墨) is the ink of Japanese calligraphy and ink painting: ground from soot, laid down with a
    brush, meant to last. The app keeps your handwriting exactly as you wrote it, in crisp vector ink, and makes it
    searchable. Today's S stays the mark; the blue full stop becomes <b>ai-iro</b>, Japanese indigo.</p>
    <div class="cap" style="margin-top:18px">Tagline ideas</div>
    <p class="list">Your notes, in ink. · Ink that travels. · Every stroke, everywhere. · Read your handwriting anywhere.</p>
  </div>
  <div class="card"><div class="cap">Palette</div>
    <div class="sw">
      <div style="background:#151515;color:#eee"><b>Sumi</b>#151515</div>
      <div style="background:#8A8780;color:#fff"><b>Usuzumi</b>#8A8780 thin ink</div>
    </div>
    <div class="sw">
      <div style="background:#EDE9DF"><b>Washi</b>#EDE9DF</div>
      <div style="background:#2B4C8C;color:#fff"><b>Ai-iro</b>#2B4C8C indigo</div>
      <div style="background:#5D86D6;color:#fff"><b>Ai, light</b>#5D86D6 dark mode</div>
    </div>
    <div class="cap" style="margin-top:18px">App Store</div>
    <p class="list"><b>Sumi for Supernote</b> (18 / 30)<br>View &amp; search your handwriting<br>
    Notebooks &amp; marked-up PDFs<br>Your notebooks, on iPhone</p>
  </div>
  <div class="card"><div class="cap">Wordmark</div>
    <div class="mark2"><span class="a">Sumi<i>.</i></span><span class="b">sumi<i>.</i></span></div>
    <p class="list">Didone serif for the name (calm, editorial, like the paper icon) or a light lowercase sans for a
    quieter, more modern feel. The indigo full stop carries over from the icon either way.</p>
    <div class="cap" style="margin-top:18px">App family</div>
    <p class="list"><b>Sumi</b> · iPhone &amp; iPad<br><b>Sumi</b> · Mac viewer<br><b>Sumi Preview Bridge</b> · Mac<br>
    <b>Sumi Quick Look</b> · Finder previews</p>
  </div>
</div>
"""


def esc(s):
    return html.escape(s, quote=True)


def page(name, groups, lockup_ids, extra=""):
    out = [f'<!doctype html><html><head><meta charset="utf-8"><style>{CSS}</style></head><body>']
    count = sum(len(v) for v in groups.values())
    out.append(f'<h1>{name} <span style="color:#2B4C8C">for Supernote</span>'
               f'<small>Icon concepts: {len(groups)} ideas, {count} icons. Every icon is full-bleed; '
               f'iOS applies the rounded mask.</small></h1>')
    out.append('<div class="lockups">')
    for ident, style in lockup_ids:
        out.append(f'<div class="lockup {style}"><img src="png/{ident}.png"><div><div class="w">{name}</div>'
                   f'<div class="s">for Supernote</div></div></div>')
    out.append('</div>')
    out.append(extra)
    for concept, items in groups.items():
        first = items[0][0]
        out.append(f'<div class="card"><div class="head"><h2>{esc(concept)}</h2><p>{esc(ABOUT.get(concept, ""))}</p></div>'
                   '<div class="row"><div class="ways">')
        for ident, label in items:
            out.append(f'<div class="way"><img src="png/{ident}.png">{esc(label)}</div>')
        out.append('</div><div class="side">')
        out.append('<div><div class="cap">Sizes: 120 · 87 · 60 · 40 · 29 pt</div><div class="ladder">'
                   + "".join(f'<img src="png/{first}.png" width="{s}" height="{s}">' for s in (120, 87, 60, 40, 29))
                   + '</div></div>')
        out.append(f'<div><div class="cap">App Store search</div><div class="store"><img src="png/{first}.png">'
                   f'<div><div class="t">{name} for Supernote</div><div class="st">{SUBTITLE[name]}</div>'
                   f'<div class="stars">★★★★★ &nbsp;Productivity</div></div><span class="get">Get</span></div></div>')
        out.append('<div><div class="cap">Home screen</div><div class="home">'
                   '<div><i></i>Notes</div><div><i></i>Files</div>'
                   f'<div><img src="png/{first}.png">{name}</div><div><i></i>Books</div><div><i></i>Mail</div>'
                   '</div></div>')
        out.append('</div></div></div>')
    height = 380 + 210 + len(groups) * 470 + (760 if extra else 0)
    out.append(f'<div data-height="{height}"></div></body></html>')
    return "\n".join(out)


def main():
    groups = {"Sumi": OrderedDict(), "Remora": OrderedDict(), "Quire": OrderedDict()}
    with open(os.path.join(BUILD, "icons.tsv")) as fh:
        for line in fh:
            ident, name, concept, label = line.rstrip("\n").split("\t")
            groups[name].setdefault(concept, []).append((ident, label))
    lockups = {
        "Sumi": [("sumi-today-washi", "light"), ("sumi-brush-navy", "navy"), ("sumi-brush-ink", "dark")],
        "Remora": [("remora-silhouette-plain", "light"), ("remora-nibfish-navy", "navy"),
                   ("remora-calligraphic-ink", "dark")],
        "Quire": [("quire-type-plain", "light"), ("quire-pen-navy", "navy"), ("quire-monogram-ink", "dark")],
    }
    for name, g in groups.items():
        with open(os.path.join(BUILD, f"sheet-{name.lower()}.html"), "w") as fh:
            fh.write(page(name, g, lockups[name], BRAND if name == "Sumi" else ""))
    print("wrote sheets")


if __name__ == "__main__":
    main()
