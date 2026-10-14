#!/usr/bin/env python3
"""Generate docs/flow-queue.svg: one batch (two stacked issues) moving through the squad pipeline.

Run: python3 docs/flow-queue.py   (edit STATIONS / STEPS, then commit both files)"""
import os
import sys

OUT = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(os.path.abspath(__file__)), "flow-queue.svg")
SLOT = 1.8  # seconds per step
STATIONS = [
    ("/chisel", "Chisel", "step"),
    ("you", "Review issues", "gate"),
    ("/ralph", "Ralph", "step"),
    ("agent", "Cody", "step"),
    ("agent", "Reven", "step"),
    ("you", "Merge", "gate"),
    ("SessionEnd", "lore-checkpoint", "hook"),
]
# (caption, #12 station, #13 station)
STEPS = [
    ("Chisel opens issues #12 and #13, both labelled needs-review", 0, 0),
    ("You lift the needs-review gate", 1, 1),
    ("Ralph runs the batch in dependency order, #12 first", 2, 2),
    ("Cody writes failing tests for #12, then code until green", 3, 2),
    ("Cody opens PR #12 against main. Reven reviews it", 4, 2),
    ("#13 branches from #12's branch. Tests first again", 4, 3),
    ("PR #13 is stacked on #12's branch. Reven diffs against that base", 4, 4),
    ("You retarget #13 to main, then merge #12", 5, 4),
    ("Then #13 merges", 5, 5),
    ("SessionEnd: lore-checkpoint updates status.md", 6, 6),
    (None, None, None),  # fade out, loop
]
N = len(STEPS)
DUR = SLOT * N
W, H = 1200, 290
BOX_W, BOX_H, BOX_Y = 140, 64, 30
X0 = 40 + BOX_W / 2
DX = (W - 80 - BOX_W) / (len(STATIONS) - 1)
TRACK_Y = 122
LANES = {"12": 152, "13": 190}
PILL_W, PILL_H = 56, 26


def cx(i):
    return X0 + i * DX


def pct(x):
    return f"{x * 100:.3f}%"


def move_keyframes(name, positions):
    """translate keyframes: move in the first 15% of a step, hold for the rest."""
    lines = []
    last = None
    for s, pos in enumerate(positions):
        p = pos if pos is not None else last
        if p is None:
            p = 0
        start, settle = s / N, (s + 0.15) / N
        x = cx(p)
        if s == 0:
            lines.append(f"{pct(0)}{{transform:translate({x:.1f}px,0)}}")
        else:
            lines.append(f"{pct(start)}{{transform:translate({cx(last):.1f}px,0)}}")
            lines.append(f"{pct(settle)}{{transform:translate({x:.1f}px,0)}}")
        last = p
    lines.append(f"100%{{transform:translate({cx(last):.1f}px,0)}}")
    return f"@keyframes {name}{{{''.join(lines)}}}"


def window_keyframes(name, first, last_excl):
    """opacity 1 from step `first` up to (not incl.) step `last_excl`, with short fades."""
    f = 0.08 / N
    a, b = first / N, last_excl / N
    pts = []
    if a > 0:
        pts += [f"0%{{opacity:0}}", f"{pct(a)}{{opacity:0}}"]
    pts.append(f"{pct(a + f) if a > 0 else '0%'}{{opacity:1}}")
    pts.append(f"{pct(b - f)}{{opacity:1}}")
    pts.append(f"{pct(b)}{{opacity:0}}")
    if b < 1:
        pts.append("100%{opacity:0}")
    return f"@keyframes {name}{{{''.join(pts)}}}"


css = []
anim = []

# tokens
for tok, idx in (("12", 1), ("13", 2)):
    positions = [st[idx] for st in STEPS]
    css.append(move_keyframes(f"mv{tok}", positions))
    anim.append(f"#t{tok}{{animation:mv{tok} {DUR}s linear infinite}}")
    css.append(window_keyframes(f"vis{tok}", 0, N - 1))
    anim.append(f"#t{tok} .body{{animation:vis{tok} {DUR}s linear infinite}}")

# base tags and merged marks: (id, from step, until step)
WINDOWS = [
    ("b12", 4, N - 1),   # #12 -> main
    ("b13s", 6, 7),      # #13 -> 12-...
    ("b13m", 7, N - 1),  # #13 -> main after retarget
    ("m12", 7, N - 1),
    ("m13", 8, N - 1),
    ("red12", 3, 3.5), ("grn12", 3.5, 4),
    ("red13", 5, 5.5), ("grn13", 5.5, 6),
]
for wid, a, b in WINDOWS:
    css.append(window_keyframes(f"w_{wid}", a, b))
    anim.append(f"#{wid}{{opacity:0;animation:w_{wid} {DUR}s linear infinite}}")

# captions and station highlights
for s, (cap, p12, p13) in enumerate(STEPS):
    if cap is None:
        continue
    css.append(window_keyframes(f"c{s}", s, s + 1))
    anim.append(f"#c{s}{{opacity:0;animation:c{s} {DUR}s linear infinite}}")
ACTIVE = [0, 1, 2, 3, 4, 3, 4, 5, 5, 6]  # station highlighted per step
for i in range(len(STATIONS)):
    active = [s for s, st in enumerate(ACTIVE) if st == i]
    if not active:
        continue
    runs, start, prev = [], active[0], active[0]
    for s in active[1:]:
        if s != prev + 1:
            runs.append((start, prev + 1)); start = s
        prev = s
    runs.append((start, prev + 1))
    pts = ["0%{opacity:0}"]
    f = 0.08 / N
    for a, b in runs:
        pts += [f"{pct(a / N)}{{opacity:0}}", f"{pct(a / N + f)}{{opacity:1}}",
                f"{pct(b / N - f)}{{opacity:1}}", f"{pct(b / N)}{{opacity:0}}"]
    pts.append("100%{opacity:0}")
    css.append(f"@keyframes hl{i}{{{''.join(pts)}}}")
    anim.append(f"#hl{i}{{opacity:0;animation:hl{i} {DUR}s linear infinite}}")

# static frame for reduced motion: step 6 (both PRs open, stacked)
static = [
    f"#t12{{transform:translate({cx(4):.1f}px,0)}}",
    f"#t13{{transform:translate({cx(4):.1f}px,0)}}",
    "#b12,#b13s{opacity:1}",
    "#cstatic{opacity:1}",
]

out = []
out.append(f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {H}" width="{W}" height="{H}" role="img" aria-labelledby="ttl dsc">')
out.append('<title id="ttl">Agent Squad: one batch through the pipeline</title>')
out.append('<desc id="dsc">Two stacked issues move from Chisel through the review gate, Ralph, Cody (tests first), Reven and merge, '
           'with the child PR retargeted to main before the parent merges, ending at lore-checkpoint.</desc>')
out.append("<style>")
out.append(""":root{--bg:#f6f7f9;--surface:#fff;--ink:#1c2230;--muted:#5d6675;--line:#d7dce4;--accent:#0f766e;--accent-soft:#d9f0ec;
--hook:#6d4fc2;--hook-soft:#ebe6fb;--red:#b91c1c;--green:#15803d}
@media (prefers-color-scheme:dark){:root{--bg:#12161d;--surface:#1a2029;--ink:#e8ebf0;--muted:#9aa3b2;--line:#2d3542;--accent:#2dd4bf;
--accent-soft:#113b37;--hook:#a78bfa;--hook-soft:#2a2347;--red:#f87171;--green:#4ade80}}
text{font-family:system-ui,-apple-system,"Segoe UI",sans-serif;fill:var(--ink)}
.mono{font-family:ui-monospace,SFMono-Regular,Menlo,monospace}
.bg{fill:var(--bg)}
.box{fill:var(--surface);stroke:var(--line);stroke-width:1}
.box.gate{stroke-dasharray:4 3}
.box.hook{fill:var(--hook-soft);stroke:var(--hook)}
.cmd{font-size:12px;fill:var(--accent)}
.cmd.hook{fill:var(--hook)}
.name{font-size:15px;font-weight:600}
.hl{fill:none;stroke:var(--accent);stroke-width:2.5}
.track{stroke:var(--line);stroke-width:2;stroke-dasharray:2 6;stroke-linecap:round}
.pill{fill:var(--accent-soft);stroke:var(--accent);stroke-width:1.5}
.pill.merged{fill:var(--accent);stroke:var(--accent)}
.tid{font-size:13px;font-weight:600}
.tid.on{fill:var(--surface)}
.tag{font-size:12px;fill:var(--muted)}
.red{font-size:12px;fill:var(--red)}
.grn{font-size:12px;fill:var(--green)}
.cap{font-size:15px;fill:var(--ink)}
.capstep{font-size:12px;fill:var(--muted)}
#cstatic{opacity:0}
""")
out.append("\n".join(css))
out.append("@media (prefers-reduced-motion:no-preference){" + "\n".join(anim) + "}")
out.append("@media (prefers-reduced-motion:reduce){" + "".join(static) + "}")
out.append("</style>")
out.append(f'<rect class="bg" x="0" y="0" width="{W}" height="{H}" rx="8"/>')
out.append(f'<line class="track" x1="{cx(0):.1f}" y1="{TRACK_Y}" x2="{cx(len(STATIONS) - 1):.1f}" y2="{TRACK_Y}"/>')

for i, (cmd, name, kind) in enumerate(STATIONS):
    x = cx(i) - BOX_W / 2
    out.append(f'<rect class="box {kind}" x="{x:.1f}" y="{BOX_Y}" width="{BOX_W}" height="{BOX_H}" rx="6"/>')
    out.append(f'<rect id="hl{i}" class="hl" x="{x - 3:.1f}" y="{BOX_Y - 3}" width="{BOX_W + 6}" height="{BOX_H + 6}" rx="8"/>')
    ccls = "cmd mono hook" if kind == "hook" else "cmd mono"
    out.append(f'<text class="{ccls}" x="{x + 12:.1f}" y="{BOX_Y + 24}">{cmd}</text>')
    out.append(f'<text class="name" x="{x + 12:.1f}" y="{BOX_Y + 46}">{name}</text>')
    if i < len(STATIONS) - 1:
        ax = cx(i) + BOX_W / 2 + 4
        out.append(f'<path d="M{ax:.1f} {BOX_Y + BOX_H / 2} h{DX - BOX_W - 8:.1f}" stroke="var(--accent)" stroke-width="1.5" marker-end="url(#arr)"/>')

out.insert(3, '<defs><marker id="arr" viewBox="0 0 8 8" refX="7" refY="4" markerWidth="7" markerHeight="7" orient="auto">'
              '<path d="M0 0L8 4L0 8z" fill="var(--accent)"/></marker></defs>')


def token(tok, y, tags):
    g = [f'<g id="t{tok}"><g class="body">']
    px, py = -PILL_W / 2, y - PILL_H / 2
    g.append(f'<rect class="pill" x="{px}" y="{py}" width="{PILL_W}" height="{PILL_H}" rx="13"/>')
    g.append(f'<text class="tid" x="0" y="{y + 4.5}" text-anchor="middle">#{tok}</text>')
    g.append(f'<g id="m{tok}"><rect class="pill merged" x="{px}" y="{py}" width="{PILL_W}" height="{PILL_H}" rx="13"/>'
             f'<text class="tid on" x="0" y="{y + 4.5}" text-anchor="middle">#{tok}</text></g>')
    for tid, cls, txt in tags:
        g.append(f'<text id="{tid}" class="{cls} mono" x="{PILL_W / 2 + 8}" y="{y + 4.5}">{txt}</text>')
    g.append("</g></g>")
    return "".join(g)


out.append(token("12", LANES["12"], [("b12", "tag", "→ main"), ("red12", "red", "✗ tests"), ("grn12", "grn", "✓ tests")]))
out.append(token("13", LANES["13"], [("b13s", "tag", "→ 12-…"), ("b13m", "tag", "→ main"), ("red13", "red", "✗ tests"), ("grn13", "grn", "✓ tests")]))

CAP_Y = 250
for s, (cap, _, _) in enumerate(STEPS):
    if cap is None:
        continue
    out.append(f'<g id="c{s}"><text class="capstep mono" x="{W / 2}" y="{CAP_Y - 20}" text-anchor="middle">step {s + 1} of {N - 1}</text>'
               f'<text class="cap" x="{W / 2}" y="{CAP_Y + 2}" text-anchor="middle">{cap.replace("&", "&amp;")}</text></g>')
out.append(f'<text id="cstatic" class="cap" x="{W / 2}" y="{CAP_Y + 2}" text-anchor="middle">'
           'Two stacked PRs after review: #13 is based on #12\'s branch until you retarget it to main</text>')
out.append("</svg>")

with open(OUT, "w") as fh:
    fh.write("\n".join(out) + "\n")
