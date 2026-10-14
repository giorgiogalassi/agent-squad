#!/usr/bin/env python3
"""Generate docs/flow-queue.svg: one batch (two stacked issues) moving through the squad pipeline.

Run: python3 docs/flow-queue.py   (edit STATIONS / STEPS, then commit both files)"""
import os
import sys

OUT = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(os.path.abspath(__file__)), "flow-queue.svg")
SLOT = 1.3  # seconds per step

# key, cmd label, name, kind
STATIONS = [
    ("forge", "/forge", "Forge", "step"),
    ("chisel", "/chisel", "Chisel", "step"),
    ("gate", "you", "Review issues", "gate"),
    ("ralph", "/ralph", "Ralph", "step"),
    ("cody", "agent", "Cody", "step"),
    ("reven", "/reven", "Reven", "step"),
    ("merge", "you", "Merge", "gate"),
    ("ckpt", "SessionEnd", "lore-checkpoint", "hook"),
]
SIDE = ("sidecar", "/sidecar", "Sidecar", "side")  # side path, below the track

# caption, plan token, #12, #13, highlighted station
STEPS = [
    ("Forge plans the change and sizes it", "forge", None, None, "forge"),
    ("Chisel turns the plan into issues #12 and #13, both labelled needs-review", None, "chisel", "chisel", "chisel"),
    ("You lift the needs-review gate", None, "gate", "gate", "gate"),
    ("Ralph's loop, issue 1 of 2: #12 goes to Cody", None, "ralph", "ralph", "ralph"),
    ("Cody writes failing tests for #12, then code until green, then opens PR #12", None, "cody", "ralph", "cody"),
    ("Ralph loops, issue 2 of 2: #13 branches from #12's branch", None, "cody", "cody", "ralph"),
    ("Tests first again. PR #13 is stacked on #12's branch", None, "cody", "cody", "cody"),
    ("You run Reven on each PR. Each diffs against its own base", None, "reven", "reven", "reven"),
    ("You fix a review note on #13 in a sidecar worktree. “Done” pushes it", None, "reven", "sidecar", "sidecar"),
    ("You retarget #13 to main, then merge #12", None, "merge", "reven", "merge"),
    ("Then #13 merges", None, "merge", "merge", "merge"),
    ("SessionEnd: lore-checkpoint updates status.md", None, "ckpt", "ckpt", "ckpt"),
    (None, None, None, None, None),  # fade out, loop
]
# time windows (in steps) for overlays
WINDOWS = {
    "b13s": (7, 8),                # #13 -> 12-... once tests are done (hidden in the sidecar)
    "b13m": (9, 10),               # #13 -> main: the retarget
    "mg12": (9, 11.9), "mg13": (10, 11.9),  # merged labels, only at the end
    "m12": (9, 11.9), "m13": (10, 11.9),
    "red12": (4, 4.45), "grn12": (4.45, 5),
    "red13": (6, 6.45), "grn13": (6.45, 7),
    "fix13": (8, 9),
    "n1": (3, 5), "n2": (5, 7),    # Ralph counter
    "loop": (3, 7),                # Ralph <-> Cody loop arc visible/flowing
}

N = len(STEPS)
DUR = round(SLOT * N, 2)
W, H = 1280, 400
BOX_W, BOX_H, BOX_Y = 132, 64, 56
MARGIN = 24
X0 = MARGIN + BOX_W / 2
DX = (W - 2 * MARGIN - BOX_W) / (len(STATIONS) - 1)
TRACK_Y = BOX_Y + BOX_H + 26
LANE = {"plan": TRACK_Y + 28, "12": TRACK_Y + 28, "13": TRACK_Y + 64}
PILL_W, PILL_H = 56, 26
IDX = {k: i for i, (k, *_r) in enumerate(STATIONS)}
SIDE_X = (IDX["reven"] + IDX["merge"]) / 2  # sidecar sits between Reven and Merge
SIDE_Y = TRACK_Y + 104
CAP_Y = H - 26


def cx(i):
    return X0 + i * DX


def pos(key, lane):
    """(x, dy) for a token: dy is the offset from its own lane."""
    if key == "sidecar":
        return cx(SIDE_X) - BOX_W / 2 - PILL_W / 2 - 10, SIDE_Y + BOX_H / 2 - LANE[lane]
    return cx(IDX[key]), 0.0


def pct(x):
    return f"{x * 100:.3f}%"


def tf(p):
    return f"transform:translate({p[0]:.1f}px,{p[1]:.1f}px)"


def move_keyframes(name, keys, lane):
    """move in the first 15% of a step, hold for the rest."""
    frames, last = [], None
    for s, k in enumerate(keys):
        p = pos(k, lane) if k else last
        if p is None:
            continue
        if last is None:
            frames.append(f"0%{{{tf(p)}}}")
        else:
            frames.append(f"{pct(s / N)}{{{tf(last)}}}")
            frames.append(f"{pct((s + 0.15) / N)}{{{tf(p)}}}")
        last = p
    frames.append(f"100%{{{tf(last)}}}")
    return f"@keyframes {name}{{{''.join(frames)}}}"


def window_keyframes(name, runs):
    f = 0.06 / N
    pts = ["0%{opacity:0}"]
    for a, b in runs:
        a, b = a / N, b / N
        pts += [f"{pct(a)}{{opacity:0}}", f"{pct(a + f)}{{opacity:1}}",
                f"{pct(b - f)}{{opacity:1}}", f"{pct(b)}{{opacity:0}}"]
    pts.append("100%{opacity:0}")
    return f"@keyframes {name}{{{''.join(pts)}}}"


def runs_of(steps):
    steps = sorted(steps)
    runs, start, prev = [], steps[0], steps[0]
    for s in steps[1:]:
        if s != prev + 1:
            runs.append((start, prev + 1))
            start = s
        prev = s
    runs.append((start, prev + 1))
    return runs


css, anim = [], []


def animate(sel, kf_name, kf):
    css.append(kf)
    anim.append(f"{sel}{{animation:{kf_name} {DUR}s linear infinite}}")


# tokens
for tok, col in (("plan", 1), ("12", 2), ("13", 3)):
    keys = [st[col] for st in STEPS]
    animate(f"#t{tok}", f"mv{tok}", move_keyframes(f"mv{tok}", keys, tok))
    visible = [s for s, k in enumerate(keys) if k]
    animate(f"#t{tok}>.body", f"vis{tok}", window_keyframes(f"vis{tok}", runs_of(visible)))

for wid, (a, b) in WINDOWS.items():
    animate(f"#{wid}", f"w_{wid}", window_keyframes(f"w_{wid}", [(a, b)]))
anim.append(f"#loop .flow{{animation:dash 0.8s linear infinite}}")
css.append("@keyframes dash{to{stroke-dashoffset:-12}}")

for s, st in enumerate(STEPS):
    if st[0]:
        animate(f"#c{s}", f"c{s}", window_keyframes(f"c{s}", [(s, s + 1)]))
for key in [k for k, *_r in STATIONS] + [SIDE[0]]:
    active = [s for s, st in enumerate(STEPS) if st[4] == key]
    if active:
        animate(f"#hl_{key}", f"hl_{key}", window_keyframes(f"hl_{key}", runs_of(active)))

# reduced motion: step 7 (both PRs open, stacked, under review)
static = (f"#t12{{{tf(pos('reven', '12'))}}}#t13{{{tf(pos('reven', '13'))}}}"
          "#t12>.body,#t13>.body,#b13s,#cstatic,#loop{opacity:1}")

out = [f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {H}" width="{W}" height="{H}" role="img" aria-labelledby="ttl dsc">',
       '<title id="ttl">Agent Squad: one batch through the pipeline</title>',
       '<desc id="dsc">Forge plans, Chisel opens two issues, you lift the review gate, Ralph loops Cody over each issue '
       '(tests first, the second PR stacked on the first), you review with Reven and fix one note in a sidecar, '
       'retarget the child PR to main and merge both, and lore-checkpoint updates status.</desc>',
       '<defs><marker id="arr" viewBox="0 0 8 8" refX="7" refY="4" markerWidth="7" markerHeight="7" orient="auto">'
       '<path d="M0 0L8 4L0 8z" fill="var(--accent)"/></marker>'
       '<marker id="arrh" viewBox="0 0 8 8" refX="7" refY="4" markerWidth="7" markerHeight="7" orient="auto">'
       '<path d="M0 0L8 4L0 8z" fill="var(--hook)"/></marker></defs>',
       "<style>",
       """:root{--bg:#f6f7f9;--surface:#fff;--ink:#1c2230;--muted:#5d6675;--line:#d7dce4;--accent:#0f766e;--accent-soft:#d9f0ec;
--hook:#6d4fc2;--hook-soft:#ebe6fb;--side:#b45309;--side-soft:#fdebd0;--red:#b91c1c;--green:#15803d}
@media (prefers-color-scheme:dark){:root{--bg:#12161d;--surface:#1a2029;--ink:#e8ebf0;--muted:#9aa3b2;--line:#2d3542;--accent:#2dd4bf;
--accent-soft:#113b37;--hook:#a78bfa;--hook-soft:#2a2347;--side:#f59e0b;--side-soft:#3d2a0a;--red:#f87171;--green:#4ade80}}
text{font-family:system-ui,-apple-system,"Segoe UI",sans-serif;fill:var(--ink)}
.mono{font-family:ui-monospace,SFMono-Regular,Menlo,monospace}
.bg{fill:var(--bg)}
.box{fill:var(--surface);stroke:var(--line);stroke-width:1}
.box.gate{stroke-dasharray:4 3}
.box.hook{fill:var(--hook-soft);stroke:var(--hook)}
.box.side{fill:var(--side-soft);stroke:var(--side)}
.cmd{font-size:12px;fill:var(--accent)}
.cmd.hook{fill:var(--hook)}
.cmd.side{fill:var(--side)}
.name{font-size:14px;font-weight:600}
.hl{fill:none;stroke:var(--accent);stroke-width:2.5}
.track{stroke:var(--line);stroke-width:2;stroke-dasharray:2 6;stroke-linecap:round}
.pill{fill:var(--accent-soft);stroke:var(--accent);stroke-width:1.5}
.pill.plan{fill:var(--surface);stroke-dasharray:3 3}
.pill.merged{fill:var(--accent);stroke:var(--accent)}
.tid{font-size:13px;font-weight:600}
.tid.on{fill:var(--surface)}
.tag{font-size:12px;fill:var(--muted)}
.red{font-size:12px;fill:var(--red)}
.grn{font-size:12px;fill:var(--green)}
.fix{font-size:12px;fill:var(--side)}
.badge{fill:var(--hook)}
.badgetx{font-size:11px;font-weight:600;fill:var(--surface)}
.looparc{fill:none;stroke:var(--hook);stroke-width:1.75}
.flow{stroke-dasharray:6 6}
.looplbl{font-size:12px;fill:var(--hook)}
.sidelink{fill:none;stroke:var(--side);stroke-width:1.5;stroke-dasharray:3 4}
.cap{font-size:15px}
.capstep{font-size:12px;fill:var(--muted)}
.ov{opacity:0}
""",
       "\n".join(css),
       "@media (prefers-reduced-motion:no-preference){" + "\n".join(anim) + "}",
       "@media (prefers-reduced-motion:reduce){" + static + "}",
       "</style>",
       f'<rect class="bg" x="0" y="0" width="{W}" height="{H}" rx="8"/>',
       f'<line class="track" x1="{cx(0):.1f}" y1="{TRACK_Y}" x2="{cx(len(STATIONS) - 1):.1f}" y2="{TRACK_Y}"/>']


def station(key, cmd, name, kind, x0, y0):
    o = [f'<rect class="box {kind}" x="{x0:.1f}" y="{y0}" width="{BOX_W}" height="{BOX_H}" rx="6"/>',
         f'<rect id="hl_{key}" class="hl ov" x="{x0 - 3:.1f}" y="{y0 - 3}" width="{BOX_W + 6}" height="{BOX_H + 6}" rx="8"/>',
         f'<text class="cmd mono {kind}" x="{x0 + 12:.1f}" y="{y0 + 24}">{cmd}</text>',
         f'<text class="name" x="{x0 + 12:.1f}" y="{y0 + 46}">{name}</text>']
    return "".join(o)


for i, (key, cmd, name, kind) in enumerate(STATIONS):
    out.append(station(key, cmd, name, kind, cx(i) - BOX_W / 2, BOX_Y))
    if i < len(STATIONS) - 1:
        ax = cx(i) + BOX_W / 2 + 3
        out.append(f'<path d="M{ax:.1f} {BOX_Y + BOX_H / 2} h{DX - BOX_W - 6:.1f}" stroke="var(--accent)" stroke-width="1.5" marker-end="url(#arr)"/>')

# sidecar side path: dashed links up to the track from Reven and back toward Merge
sx = cx(SIDE_X)
out.append(f'<path class="sidelink" d="M{cx(IDX["reven"]):.1f} {LANE["13"] + 20} Q{cx(IDX["reven"]):.1f} {SIDE_Y + BOX_H / 2} {sx - BOX_W / 2:.1f} {SIDE_Y + BOX_H / 2}"/>')
out.append(f'<path class="sidelink" d="M{sx + BOX_W / 2:.1f} {SIDE_Y + BOX_H / 2} Q{cx(IDX["merge"]):.1f} {SIDE_Y + BOX_H / 2} {cx(IDX["merge"]):.1f} {LANE["13"] + 20}"/>')
out.append(station(SIDE[0], SIDE[1], SIDE[2], SIDE[3], sx - BOX_W / 2, SIDE_Y))

# Ralph <-> Cody loop arc above the boxes, plus the issue counter badge on Ralph
rx_, cx_ = cx(IDX["ralph"]), cx(IDX["cody"])
top = BOX_Y - 2
arc = f"M{cx_ - 20:.1f} {top} C{cx_ - 20:.1f} {top - 40} {rx_ + 20:.1f} {top - 40} {rx_ + 20:.1f} {top}"
out.append(f'<path class="looparc" d="{arc}" stroke-opacity="0.35" marker-end="url(#arrh)"/>')
out.append(f'<g id="loop" class="ov"><path class="looparc flow" d="{arc}" marker-end="url(#arrh)"/></g>')
out.append(f'<text class="looplbl" x="{(rx_ + cx_) / 2:.1f}" y="{top - 34}" text-anchor="middle">↻ next issue</text>')
bx, by = rx_ + BOX_W / 2 - 22, BOX_Y + 12
for nid, txt in (("n1", "1/2"), ("n2", "2/2")):
    out.append(f'<g id="{nid}" class="ov"><rect class="badge" x="{bx - 16:.1f}" y="{by - 9}" width="32" height="18" rx="9"/>'
               f'<text class="badgetx mono" x="{bx:.1f}" y="{by + 4}" text-anchor="middle">{txt}</text></g>')


def token(tok, label, tags, plan=False):
    y = LANE[tok]
    px, py = -PILL_W / 2, y - PILL_H / 2
    g = [f'<g id="t{tok}"><g class="body ov">',
         f'<rect class="pill{" plan" if plan else ""}" x="{px}" y="{py}" width="{PILL_W}" height="{PILL_H}" rx="13"/>',
         f'<text class="tid" x="0" y="{y + 4.5}" text-anchor="middle">{label}</text>']
    if not plan:
        g.append(f'<g id="m{tok}" class="ov"><rect class="pill merged" x="{px}" y="{py}" width="{PILL_W}" height="{PILL_H}" rx="13"/>'
                 f'<text class="tid on" x="0" y="{y + 4.5}" text-anchor="middle">{label}</text></g>')
    for tid, cls, txt in tags:
        g.append(f'<text id="{tid}" class="{cls} mono ov" x="{PILL_W / 2 + 8}" y="{y + 4.5}">{txt}</text>')
    g.append("</g></g>")
    return "".join(g)


out.append(token("plan", "plan", [], plan=True))
out.append(token("12", "#12", [("mg12", "grn", "✓ merged"), ("red12", "red", "✗ tests"), ("grn12", "grn", "✓ tests")]))
out.append(token("13", "#13", [("b13s", "tag", "→ 12-…"), ("b13m", "tag", "→ main"), ("red13", "red", "✗ tests"),
                              ("grn13", "grn", "✓ tests"), ("mg13", "grn", "✓ merged")]))
# the sidecar fix note sits beside #13 while it is in the sidecar; position it absolutely
fx, fy = cx(SIDE_X) + BOX_W / 2 + 10, SIDE_Y + BOX_H / 2 + 4
out.append(f'<text id="fix13" class="fix mono ov" x="{fx:.1f}" y="{fy}">fix review note</text>')

for s, st in enumerate(STEPS):
    if st[0]:
        out.append(f'<g id="c{s}" class="ov"><text class="capstep mono" x="{W / 2}" y="{CAP_Y - 20}" text-anchor="middle">step {s + 1} of {N - 1}</text>'
                   f'<text class="cap" x="{W / 2}" y="{CAP_Y + 2}" text-anchor="middle">{st[0].replace("&", "&amp;")}</text></g>')
out.append(f'<text id="cstatic" class="cap ov" x="{W / 2}" y="{CAP_Y + 2}" text-anchor="middle">'
           "Both PRs under review: #13 is stacked on #12’s branch until you retarget it to main</text>")
out.append("</svg>")

with open(OUT, "w") as fh:
    fh.write("\n".join(out) + "\n")
