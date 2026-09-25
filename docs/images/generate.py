#!/usr/bin/env python3
"""Draws VoiceParty's README and social-preview art as plain SVG (no third-party fonts, icons or images).

    python3 docs/images/generate.py          # rewrite the SVGs next to this file
    python3 docs/images/generate.py --png    # also the PNGs (hero fallbacks + social preview), via headless Chrome

Brand tokens come from the app itself: scripts/make-icon.swift (teal squircle, white waveform) and
Sources/VoiceParty/Hub/Theme.swift (warm canvas, teal accent, serif display type). Text uses system fonts; Pillow is
used only to measure text for layout. Every name and sentence in the examples is made up.
"""
import math
import os
import shutil
import subprocess
import sys
import tempfile
from PIL import ImageFont

OUT = os.path.dirname(os.path.abspath(__file__))

SANS = "-apple-system, BlinkMacSystemFont, 'SF Pro Text', 'Segoe UI', 'Helvetica Neue', Helvetica, Arial, sans-serif"
SERIF = "ui-serif, 'New York', 'Iowan Old Style', Charter, Georgia, 'Times New Roman', serif"
MONO = "ui-monospace, 'SF Mono', SFMono-Regular, Menlo, Consolas, monospace"

# ---------------------------------------------------------------- text measuring (layout only)
_fonts = {}


def _font(kind, size, weight):
    key = (kind, size, weight)
    if key not in _fonts:
        path = {"sans": "/System/Library/Fonts/SFNS.ttf", "serif": "/System/Library/Fonts/NewYork.ttf",
                "mono": "/System/Library/Fonts/SFNSMono.ttf"}[kind]
        f = ImageFont.truetype(path, size)
        name = {400: b"Regular", 500: b"Medium", 600: b"Semibold", 700: b"Bold"}[weight]
        try:
            f.set_variation_by_name(name)
        except Exception:
            pass
        _fonts[key] = f
    return _fonts[key]


def tw(text, size, weight=400, kind="sans"):
    return _font(kind, int(round(size)), weight).getlength(text)


def wrap(text, size, width, weight=400, kind="sans"):
    words, lines, cur = text.split(" "), [], ""
    for w in words:
        trial = (cur + " " + w).strip()
        if tw(trial, size, weight, kind) <= width * 0.92 or not cur:
            cur = trial
        else:
            lines.append(cur)
            cur = w
    if cur:
        lines.append(cur)
    return lines


def esc(s):
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def f(x):
    return f"{x:.1f}".rstrip("0").rstrip(".")


# ---------------------------------------------------------------- themes
THEMES = {
    "light": dict(
        canvas="#F4F2EE", card="#FDFDFC", well="#EDEAE4", ink="#1F1E1C", muted="#6F6B65", faint="#9A968F",
        accent="#2F6965", accent_soft="#2F6965", accent_soft_op=0.10, hair="#000000", hair_op=0.08,
        strike="#B4640F", shadow_op=0.07, tile_a="#EAE7E1", tile_b="#DFDBD3", glow_op=0.10, frame="#000000",
        frame_op=0.06,
    ),
    "dark": dict(
        canvas="#1E1D1B", card="#272624", well="#33322F", ink="#EDEBE7", muted="#A7A39C", faint="#7D7A74",
        accent="#6BB8B0", accent_soft="#6BB8B0", accent_soft_op=0.14, hair="#FFFFFF", hair_op=0.09,
        strike="#F2A84D", shadow_op=0.35, tile_a="#2C2B28", tile_b="#232220", glow_op=0.10, frame="#FFFFFF",
        frame_op=0.07,
    ),
}


def style_block():
    return (f"<style>.s{{font-family:{SANS}}}.r{{font-family:{SERIF}}}.m{{font-family:{MONO}}}"
            f".p{{white-space:pre}}</style>")


def defs_common(t, extra=""):
    return f"""<defs>
  <linearGradient id="teal" x1="0.25" y1="0.07" x2="0.75" y2="0.93">
    <stop offset="0" stop-color="#173333"/><stop offset="1" stop-color="#337570"/>
  </linearGradient>
  <filter id="soft" x="-20%" y="-20%" width="140%" height="160%">
    <feDropShadow dx="0" dy="6" stdDeviation="10" flood-color="#000" flood-opacity="{t['shadow_op']}"/>
  </filter>
  <filter id="pillshadow" x="-30%" y="-60%" width="160%" height="260%">
    <feDropShadow dx="0" dy="4" stdDeviation="7" flood-color="#000" flood-opacity="0.28"/>
  </filter>
  {extra}
</defs>"""


# ---------------------------------------------------------------- brand mark
ICON_HEIGHTS = [0.18, 0.34, 0.52, 0.34, 0.24, 0.42, 0.2]


def mark(x, y, size, stroke=True, grad="teal"):
    """The app icon without its transparent margin: squircle + seven-bar waveform (make-icon.swift)."""
    r = size * 0.225
    out = [f'<g transform="translate({f(x)} {f(y)})">',
           f'<rect width="{f(size)}" height="{f(size)}" rx="{f(r)}" fill="url(#{grad})"/>']
    if stroke:
        out.append(f'<rect x="{f(size*0.004)}" y="{f(size*0.004)}" width="{f(size*0.992)}" height="{f(size*0.992)}" '
                   f'rx="{f(r)}" fill="none" stroke="#fff" stroke-opacity="0.12" stroke-width="{f(max(1, size*0.006))}"/>')
    bw, gap = size * 0.062, size * 0.045
    total = 7 * bw + 6 * gap
    bx = size / 2 - total / 2
    for h in ICON_HEIGHTS:
        hh = size * h
        out.append(f'<rect x="{f(bx)}" y="{f(size/2 - hh/2)}" width="{f(bw)}" height="{f(hh)}" rx="{f(bw/2)}" fill="#fff"/>')
        bx += bw + gap
    out.append("</g>")
    return "\n".join(out)


def write(name, body, w, h):
    svg = (f'<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}" viewBox="0 0 {w} {h}" '
           f'role="img">\n{body}\n</svg>\n')
    with open(os.path.join(OUT, name), "w") as fh:
        fh.write(svg)
    print("wrote", name)


# ---------------------------------------------------------------- dictation bar pieces (DictationBarView.swift)
def waveform(cx, cy, s, tint="#fff", level=0.85, phase=0.0, bars=11):
    """11 capsules, 2.4pt wide, 2.2pt apart, heights shaped like the live view (static frame)."""
    out = []
    width = bars * 2.4 + (bars - 1) * 2.2
    x = cx - width * s / 2
    mid = (bars - 1) / 2
    for i in range(bars):
        env = 1 - abs(i - mid) / mid * 0.55
        wob = 0.55 + 0.45 * math.sin(phase * 11 + i * 1.9)
        h = min(20, 3 + level * 17 * env * wob) * s
        out.append(f'<rect x="{f(x)}" y="{f(cy - h/2)}" width="{f(2.4*s)}" height="{f(h)}" rx="{f(1.2*s)}" fill="{tint}"/>')
        x += (2.4 + 2.2) * s
    return "\n".join(out)


def pill_bg(x, y, w, h, s, fill="#000", op=0.94, stroke_op=0.22):
    r = h / 2
    return (f'<g filter="url(#pillshadow)"><rect x="{f(x)}" y="{f(y)}" width="{f(w)}" height="{f(h)}" rx="{f(r)}" '
            f'fill="{fill}" fill-opacity="{op}"/></g>'
            f'<rect x="{f(x+0.5*s)}" y="{f(y+0.5*s)}" width="{f(w-s)}" height="{f(h-s)}" rx="{f(r-0.5*s)}" fill="none" '
            f'stroke="#fff" stroke-opacity="{stroke_op}" stroke-width="{f(s)}"/>')


def circle_button(cx, cy, s, symbol, filled):
    bg = "#fff" if filled else "#3D3D3D"
    fg = "#000" if filled else "#fff"
    out = [f'<circle cx="{f(cx)}" cy="{f(cy)}" r="{f(10*s)}" fill="{bg}"/>']
    sw = 1.7 * s
    if symbol == "x":
        d = 3.0 * s
        out.append(f'<path d="M{f(cx-d)} {f(cy-d)} L{f(cx+d)} {f(cy+d)} M{f(cx+d)} {f(cy-d)} L{f(cx-d)} {f(cy+d)}" '
                   f'stroke="{fg}" stroke-width="{f(sw)}" stroke-linecap="round"/>')
    elif symbol == "check":
        out.append(f'<path d="M{f(cx-3.6*s)} {f(cy+0.2*s)} L{f(cx-1.1*s)} {f(cy+2.8*s)} L{f(cx+3.8*s)} {f(cy-2.9*s)}" '
                   f'fill="none" stroke="{fg}" stroke-width="{f(sw)}" stroke-linecap="round" stroke-linejoin="round"/>')
    elif symbol == "stop":
        out.append(f'<rect x="{f(cx-3.6*s)}" y="{f(cy-3.6*s)}" width="{f(7.2*s)}" height="{f(7.2*s)}" rx="{f(1.3*s)}" fill="{fg}"/>')
    return "\n".join(out)


def star(cx, cy, r, fill):
    """A four-point sparkle with concave sides (drawn here, not a system symbol)."""
    k = r * 0.28
    return (f'<path d="M{f(cx)} {f(cy-r)} Q{f(cx+k)} {f(cy-k)} {f(cx+r)} {f(cy)} Q{f(cx+k)} {f(cy+k)} {f(cx)} {f(cy+r)} '
            f'Q{f(cx-k)} {f(cy+k)} {f(cx-r)} {f(cy)} Q{f(cx-k)} {f(cy-k)} {f(cx)} {f(cy-r)} Z" fill="{fill}"/>')


def sparkles(cx, cy, s, fill="#C7A8FF"):
    return star(cx - 0.8 * s, cy + 0.9 * s, 5.2 * s, fill) + star(cx + 4.4 * s, cy - 3.6 * s, 2.4 * s, fill)


def pill_hold(cx, cy, s):
    w, h = 86.4 * s, 30 * s
    return pill_bg(cx - w / 2, cy - h / 2, w, h, s) + waveform(cx, cy, s, phase=0.3)


def pill_handsfree(cx, cy, s):
    w, h = 114.4 * s, 30 * s
    x0 = cx - w / 2
    return (pill_bg(x0, cy - h / 2, w, h, s) + circle_button(x0 + 15 * s, cy, s, "x", False)
            + waveform(cx, cy, s, phase=1.1) + circle_button(x0 + w - 15 * s, cy, s, "check", True))


def pill_command(cx, cy, s):
    w, h = 110 * s, 30 * s
    x0 = cx - w / 2
    return (pill_bg(x0, cy - h / 2, w, h, s) + sparkles(x0 + 16 * s, cy, s)
            + waveform(x0 + 28 * s + 24.2 * s + 4 * s, cy, s, tint="#DBCCFF", phase=2.0)
            + circle_button(x0 + w - 15 * s, cy, s, "check", True))


def pill_processing(cx, cy, s):
    w, h = 73.5 * s, 30 * s
    out = [pill_bg(cx - w / 2, cy - h / 2, w, h, s)]
    x = cx - 33.5 * s / 2 + 1.75 * s
    for i, op in enumerate([1.0, 0.85, 0.6, 0.42, 0.35]):
        out.append(f'<circle cx="{f(x)}" cy="{f(cy)}" r="{f(1.75*s)}" fill="#fff" fill-opacity="{op}"/>')
        x += 7.5 * s
    return "\n".join(out)


def pill_resting(cx, cy, s):
    w, h = 44 * s, 9 * s
    return (f'<rect x="{f(cx-w/2)}" y="{f(cy-h/2)}" width="{f(w)}" height="{f(h)}" rx="{f(h/2)}" fill="#000" fill-opacity="0.55" '
            f'stroke="#fff" stroke-opacity="0.25" stroke-width="{f(s)}"/>')


def pill_notetaker(cx, cy, s, clock="12:48"):
    notes_w = tw("Notes", 12 * s, 600) / s
    clock_w = tw(clock, 12 * s, 500) / s
    w = 12 + 7 + 8 + notes_w + 8 + clock_w + 8 + 20 + 8 + 20 + 4
    w, h = w * s, 28 * s
    x = cx - w / 2
    out = [pill_bg(x, cy - h / 2, w, h, s)]
    x += 12 * s
    out.append(f'<circle cx="{f(x+3.5*s)}" cy="{f(cy)}" r="{f(3.5*s)}" fill="#FF5C54"/>')
    x += 15 * s
    out.append(f'<text x="{f(x)}" y="{f(cy+4.3*s)}" class="s" font-size="{f(12*s)}" font-weight="600" fill="#fff">Notes</text>')
    x += (notes_w + 8) * s
    out.append(f'<text x="{f(x)}" y="{f(cy+4.3*s)}" class="s" font-size="{f(12*s)}" font-weight="500" fill="#fff" '
               f'fill-opacity="0.7" style="font-variant-numeric:tabular-nums">{clock}</text>')
    x += (clock_w + 8) * s
    # notepad glyph: a page with a pencil stroke
    px, py = x + 4.5 * s, cy - 5.5 * s
    out.append(f'<path d="M{f(px+6*s)} {f(py+1*s)} H{f(px+1.8*s)} Q{f(px)} {f(py+1*s)} {f(px)} {f(py+2.8*s)} V{f(py+9.2*s)} '
               f'Q{f(px)} {f(py+11*s)} {f(px+1.8*s)} {f(py+11*s)} H{f(px+8.2*s)} Q{f(px+10*s)} {f(py+11*s)} {f(px+10*s)} {f(py+9.2*s)} V{f(py+5.5*s)}" '
               f'fill="none" stroke="#fff" stroke-opacity="0.85" stroke-width="{f(1.2*s)}" stroke-linecap="round"/>'
               f'<path d="M{f(px+4.6*s)} {f(py+6.6*s)} L{f(px+10.6*s)} {f(py+0.6*s)}" stroke="#fff" stroke-opacity="0.85" '
               f'stroke-width="{f(1.5*s)}" stroke-linecap="round"/>')
    x += 28 * s
    out.append(circle_button(x + 10 * s, cy, s, "stop", True))
    return "\n".join(out)


def toast(x, cy, s, message, action):
    msg_w = tw(message, 13 * s, 500) / s * 1.03
    act_w = tw(action, 12 * s, 600) / s
    btn_w = act_w + 20
    w = 16 + msg_w + 12 + btn_w + 6
    h = 36
    W, H = w * s, h * s
    y = cy - H / 2
    out = [f'<g filter="url(#pillshadow)"><rect x="{f(x)}" y="{f(y)}" width="{f(W)}" height="{f(H)}" rx="{f(H/2)}" fill="#171717"/></g>',
           f'<text x="{f(x+16*s)}" y="{f(cy+4.6*s)}" class="s" font-size="{f(13*s)}" font-weight="500" fill="#fff">{esc(message)}</text>']
    bx = x + (16 + msg_w + 12) * s
    out.append(f'<rect x="{f(bx)}" y="{f(cy-12*s)}" width="{f(btn_w*s)}" height="{f(24*s)}" rx="{f(7*s)}" fill="#424242"/>')
    out.append(f'<text x="{f(bx+btn_w*s/2)}" y="{f(cy+4.2*s)}" text-anchor="middle" class="s" font-size="{f(12*s)}" '
               f'font-weight="600" fill="#fff">{esc(action)}</text>')
    # the countdown line along the bottom edge
    out.append(f'<rect x="{f(x+18*s)}" y="{f(y+H-3*s)}" width="{f((W-36*s)*0.62)}" height="{f(2*s)}" rx="{f(s)}" fill="#fff" fill-opacity="0.35"/>')
    return "\n".join(out), W


def keycap(x, y, w, h, label, t, size=22, pressed=True):
    depth = 3 if not pressed else 1.5
    return (f'<rect x="{f(x)}" y="{f(y+depth)}" width="{f(w)}" height="{f(h)}" rx="9" fill="{t["hair"]}" fill-opacity="{t["hair_op"]*2.2}"/>'
            f'<rect x="{f(x)}" y="{f(y)}" width="{f(w)}" height="{f(h)}" rx="9" fill="{t["card"]}" stroke="{t["hair"]}" '
            f'stroke-opacity="{t["hair_op"]*1.8}"/>'
            f'<text x="{f(x+w/2)}" y="{f(y+h/2+size*0.36)}" text-anchor="middle" class="s" font-size="{size}" font-weight="500" '
            f'fill="{t["ink"]}">{esc(label)}</text>')


def card(x, y, w, h, t, r=18, shadow=True, fill=None):
    fill = fill or t["card"]
    sh = f' filter="url(#soft)"' if shadow else ""
    return (f'<rect x="{f(x)}" y="{f(y)}" width="{f(w)}" height="{f(h)}" rx="{r}" fill="{fill}"{sh}/>'
            f'<rect x="{f(x+0.5)}" y="{f(y+0.5)}" width="{f(w-1)}" height="{f(h-1)}" rx="{r-0.5}" fill="none" '
            f'stroke="{t["hair"]}" stroke-opacity="{t["hair_op"]}"/>')


def label(x, y, text, t, color=None, size=13):
    return (f'<text x="{f(x)}" y="{f(y)}" class="s" font-size="{size}" font-weight="600" letter-spacing="1.4" '
            f'fill="{color or t["muted"]}">{esc(text.upper())}</text>')


def mic_glyph(x, y, color, s=1.0):
    return (f'<g transform="translate({f(x)} {f(y)}) scale({s})" fill="none" stroke="{color}" stroke-width="1.8" stroke-linecap="round">'
            f'<rect x="4.5" y="0" width="7" height="11" rx="3.5" fill="{color}" stroke="none"/>'
            f'<path d="M1.5 7.5 A6.5 6.5 0 0 0 14.5 7.5"/><path d="M8 14 V16.5"/></g>')


def lock_glyph(x, y, color, s=1.0):
    return (f'<g transform="translate({f(x)} {f(y)}) scale({s})">'
            f'<path d="M3.5 6.5 V4.8 A3.5 3.5 0 0 1 10.5 4.8 V6.5" fill="none" stroke="{color}" stroke-width="1.7"/>'
            f'<rect x="1.5" y="6.5" width="11" height="8.5" rx="2" fill="{color}"/></g>')


def rich_line(x, y, parts, size, t, weight=400, cls="s"):
    """parts: [(text, kind)] where kind is None, 'strike', 'accent' or 'code'."""
    spans = []
    for text, kind in parts:
        if kind == "strike":
            spans.append(f'<tspan fill="{t["strike"]}" text-decoration="line-through">{esc(text)}</tspan>')
        elif kind == "accent":
            spans.append(f'<tspan fill="{t["accent"]}" font-weight="600">{esc(text)}</tspan>')
        elif kind == "code":
            spans.append(f'<tspan class="m" fill="{t["accent"]}" font-size="{f(size*0.92)}">{esc(text)}</tspan>')
        elif kind == "muted":
            spans.append(f'<tspan fill="{t["muted"]}">{esc(text)}</tspan>')
        else:
            spans.append(esc(text))
    return (f'<text x="{f(x)}" y="{f(y)}" class="{cls} p" xml:space="preserve" font-size="{size}" font-weight="{weight}" '
            f'fill="{t["ink"]}">{"".join(spans)}</text>')


# ---------------------------------------------------------------- hero / social scene
RAW_1 = [("um so", "strike"), (" i think we should, ", None), ("uh,", "strike"), (" meet at ", None), ("5", "strike")]
RAW_2 = [("actually no", "strike"), (" 6 if that works", None)]
CLEAN_1 = "I think we should meet at 6"
CLEAN_2 = "if that works."


def scene(x0, y0, t, raw_color=None, guide=None):
    """'You say' card → dictation bar → 'typed where your cursor is' card, 520 wide, ~450 tall."""
    W = 520
    out = []
    guide = guide or t["faint"]
    # card A: what you say
    out.append(card(x0, y0, W, 142, t))
    out.append(mic_glyph(x0 + 28, y0 + 24, t["accent"], 0.95))
    out.append(label(x0 + 52, y0 + 38, "You say", t, t["accent"]))
    raw = dict(t)
    raw["ink"] = raw_color or t["muted"]
    out.append(rich_line(x0 + 28, y0 + 80, RAW_1, 23, raw))
    out.append(rich_line(x0 + 28, y0 + 114, RAW_2, 23, raw))
    # connector + the bar
    cx = x0 + W / 2
    out.append(f'<path d="M{f(cx)} {f(y0+150)} V{f(y0+178)}" stroke="{guide}" stroke-width="2" stroke-dasharray="2 6" stroke-linecap="round"/>')
    out.append(pill_hold(cx, y0 + 216, 2.0))
    out.append(keycap(x0 + 58, y0 + 190, 62, 50, "fn", t, 22))
    out.append(f'<text x="{f(x0+89)}" y="{f(y0+266)}" text-anchor="middle" class="s" font-size="13" font-weight="600" '
               f'letter-spacing="1.2" fill="{guide}">HOLD</text>')
    out.append(f'<path d="M{f(cx)} {f(y0+254)} V{f(y0+282)}" stroke="{guide}" stroke-width="2" stroke-dasharray="2 6" stroke-linecap="round"/>')
    # card B: what gets typed
    yb = y0 + 290
    out.append(card(x0, yb, W, 160, t))
    for i in range(3):
        out.append(f'<circle cx="{f(x0+30+i*16)}" cy="{f(yb+28)}" r="5" fill="{t["hair"]}" fill-opacity="{t["hair_op"]*2}"/>')
    out.append(label(x0 + 88, yb + 33, "Typed where your cursor is", t, t["accent"]))
    out.append(f'<text x="{f(x0+28)}" y="{f(yb+84)}" class="s" font-size="25" font-weight="500" fill="{t["ink"]}">{esc(CLEAN_1)}</text>')
    out.append(f'<text x="{f(x0+28)}" y="{f(yb+120)}" class="s" font-size="25" font-weight="500" fill="{t["ink"]}">{esc(CLEAN_2)}</text>')
    caret_x = x0 + 28 + tw(CLEAN_2, 25, 500) + 5
    out.append(f'<rect x="{f(caret_x)}" y="{f(yb+96)}" width="2.5" height="31" rx="1.2" fill="{t["accent"]}"/>')
    out.append(lock_glyph(x0 + W - 206, yb + 131, t["faint"], 0.8))
    out.append(f'<text x="{f(x0+W-190)}" y="{f(yb+142)}" class="s" font-size="13" fill="{t["faint"]}">Cleaned up on your Mac</text>')
    return "\n".join(out)


def hero(theme):
    """README banner: what you say → the dictation bar → what gets typed, left to right."""
    t = THEMES[theme]
    W, H = 1280, 400
    body = [style_block(), defs_common(t, f"""<radialGradient id="glow" cx="0.5" cy="0.5" r="0.5">
    <stop offset="0" stop-color="{t['accent']}" stop-opacity="{t['glow_op']*1.4}"/><stop offset="1" stop-color="{t['accent']}" stop-opacity="0"/>
  </radialGradient>
  <clipPath id="frame"><rect width="{W}" height="{H}" rx="28"/></clipPath>""")]
    body.append(f'<g clip-path="url(#frame)"><rect width="{W}" height="{H}" fill="{t["canvas"]}"/>'
                f'<ellipse cx="640" cy="200" rx="360" ry="220" fill="url(#glow)"/></g>')
    body.append(f'<rect x="0.5" y="0.5" width="{W-1}" height="{H-1}" rx="27.5" fill="none" stroke="{t["frame"]}" stroke-opacity="{t["frame_op"]}"/>')
    CW, CH, CY = 420, 232, 84
    ax, bx = 56, W - 56 - CW
    # card A: what you say
    body.append(card(ax, CY, CW, CH, t))
    body.append(mic_glyph(ax + 30, CY + 28, t["accent"], 0.95))
    body.append(label(ax + 56, CY + 43, "You say", t, t["accent"], 15))
    raw = dict(t)
    raw["ink"] = t["muted"]
    lines = [[("um so", "strike"), (" i think we should, ", None), ("uh,", "strike")],
             [("meet at ", None), ("5 actually no", "strike"), (" 6 if", None)],
             [("that works", None)]]
    for i, ln in enumerate(lines):
        body.append(rich_line(ax + 30, CY + 98 + i * 36, ln, 24, raw))
    # middle: the key and the bar
    cx, cy = W / 2, CY + CH / 2 + 26
    body.append(keycap(cx - 34, CY + 18, 68, 54, "fn", t, 24))
    body.append(f'<text x="{f(cx)}" y="{f(CY+98)}" text-anchor="middle" class="s" font-size="15" font-weight="600" '
                f'letter-spacing="1.4" fill="{t["faint"]}">HOLD AND TALK</text>')
    body.append(pill_hold(cx, cy, 2.0))
    for x1, x2 in ((ax + CW + 14, cx - 86.4 - 12), (cx + 86.4 + 18, bx - 16)):
        body.append(f'<path d="M{f(x1)} {f(cy)} H{f(x2)}" stroke="{t["faint"]}" stroke-width="2" stroke-dasharray="2 7" stroke-linecap="round"/>')
    for tip in (cx - 86.4 - 10, bx - 15):
        body.append(f'<path d="M{f(tip-9)} {f(cy-7)} L{f(tip)} {f(cy)} L{f(tip-9)} {f(cy+7)}" fill="none" stroke="{t["faint"]}" '
                    f'stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>')
    body.append(f'<text x="{f(cx)}" y="{f(cy+68)}" text-anchor="middle" class="s" font-size="17" fill="{t["muted"]}">Let go to insert the text</text>')
    # card B: what gets typed
    body.append(card(bx, CY, CW, CH, t))
    for i in range(3):
        body.append(f'<circle cx="{f(bx+32+i*16)}" cy="{f(CY+36)}" r="5" fill="{t["hair"]}" fill-opacity="{t["hair_op"]*2}"/>')
    body.append(label(bx + 90, CY + 42, "Typed where you are", t, t["accent"], 15))
    clean = ["I think we should meet", "at 6 if that works."]
    for i, ln in enumerate(clean):
        body.append(f'<text x="{f(bx+30)}" y="{f(CY+104+i*38)}" class="s" font-size="26" font-weight="500" fill="{t["ink"]}">{esc(ln)}</text>')
    caret_x = bx + 30 + tw(clean[-1], 26, 500) * 1.02 + 5
    body.append(f'<rect x="{f(caret_x)}" y="{f(CY+118)}" width="2.5" height="32" rx="1.2" fill="{t["accent"]}"/>')
    body.append(lock_glyph(bx + 30, CY + CH - 45, t["faint"], 0.95))
    body.append(f'<text x="{f(bx+49)}" y="{f(CY+CH-31)}" class="s" font-size="16" fill="{t["faint"]}">Transcribed and cleaned up on your Mac</text>')
    write(f"hero-{theme}.svg", "\n".join(body), W, H)


def social():
    t = dict(THEMES["light"])
    W, H = 1280, 640
    body = [style_block(), defs_common(t, """<linearGradient id="bg" x1="0" y1="0" x2="1" y2="1">
    <stop offset="0" stop-color="#0E2221"/><stop offset="1" stop-color="#1F4B47"/>
  </linearGradient>
  <radialGradient id="glow" cx="0.5" cy="0.5" r="0.5">
    <stop offset="0" stop-color="#8FD3CB" stop-opacity="0.16"/><stop offset="1" stop-color="#8FD3CB" stop-opacity="0"/>
  </radialGradient>""")]
    body.append(f'<rect width="{W}" height="{H}" fill="url(#bg)"/>')
    body.append('<circle cx="936" cy="330" r="430" fill="url(#glow)"/>')
    body.append(f'<g filter="url(#soft)">{mark(84, 110, 80)}</g>')
    body.append('<text x="184" y="166" class="s" font-size="46" font-weight="600" letter-spacing="-0.5" fill="#fff">VoiceParty</text>')
    for i, line in enumerate(["Hold a key, talk,", "and clean text appears", "where you type."]):
        body.append(f'<text x="84" y="{282 + i*62}" class="r" font-size="52" fill="#fff">{esc(line)}</text>')
    body.append('<text x="86" y="468" class="s" font-size="21" fill="#fff" fill-opacity="0.72">Private dictation for macOS. Speech recognition</text>')
    body.append('<text x="86" y="498" class="s" font-size="21" fill="#fff" fill-opacity="0.72">and cleanup run on your Mac.</text>')
    x = 84
    for chip in ["Free & open source", "macOS 26+ · Apple silicon", "On-device"]:
        w = tw(chip, 17, 500) + 32
        body.append(f'<rect x="{f(x)}" y="532" width="{f(w)}" height="38" rx="19" fill="#fff" fill-opacity="0.08" stroke="#fff" stroke-opacity="0.22"/>')
        body.append(f'<text x="{f(x+w/2)}" y="557" text-anchor="middle" class="s" font-size="17" font-weight="500" fill="#fff" fill-opacity="0.9">{esc(chip)}</text>')
        x += w + 12
    body.append(scene(676, 96, t, guide="#9CC9C3"))
    write("social-preview.svg", "\n".join(body), W, H)


def logo():
    body = defs_common(THEMES["light"]) + "\n" + mark(0, 0, 512)
    write("logo.svg", body, 512, 512)


# ---------------------------------------------------------------- "what you say → what gets typed"
EXAMPLES = [
    ("Self-corrections", [[("let's move the launch to ", None), ("wednesday actually no", "strike"), (" thursday", None)]],
     [[("Let's move the launch to Thursday.", None)]]),
    ("Fillers and lists", [[("um", "strike"), (" for the offsite ", None), ("first", "accent"), (" book the venue", None)],
                           [("second", "accent"), (" send the invites ", None), ("and", "strike"), (" ", None), ("third", "accent"), (" order lunch", None)]],
     [[("For the offsite:", None)], [("1. ", "muted"), ("Book the venue", None)], [("2. ", "muted"), ("Send the invites", None)],
      [("3. ", "muted"), ("Order lunch", None)]]),
    ("Email layout, in a mail app", [[("hi priya ", None), ("uh", "strike"), (" the demo moved to friday at 3", None)], [("talk soon sam", None)]],
     [[("Hi Priya,", None)], None, [("The demo moved to Friday at 3.", None)], None, [("Talk soon,", None)], [("Sam", None)]]),
    ("Code, in an AI code editor", [[("rename get user by id in user service dot ts", None)]],
     [[("Rename ", None), ("getUserById", "code"), (" in ", None), ("@userService.ts", "code")]]),
]


def cleanup(theme):
    t = THEMES[theme]
    W = 1280
    pad, gap = 40, 14
    lh, blank = 33, 12
    CHIP = 40  # chip height + space under it
    rows = []
    y = 104
    for tag, said, typed in EXAMPLES:
        typed_h = sum(lh if l is not None else blank for l in typed)
        said_h = CHIP + len(said) * lh
        h = max(typed_h, said_h) + 52
        rows.append((y, h, tag, said, typed, said_h, typed_h))
        y += h + gap
    H = y - gap + pad
    body = [style_block(), defs_common(t)]
    body.append(f'<rect width="{W}" height="{H}" rx="28" fill="{t["canvas"]}"/>')
    body.append(f'<rect x="0.5" y="0.5" width="{W-1}" height="{H-1}" rx="27.5" fill="none" stroke="{t["frame"]}" stroke-opacity="{t["frame_op"]}"/>')
    LX, RX = 76, 700
    body.append(mic_glyph(LX, 46, t["muted"], 0.95))
    body.append(label(LX + 26, 60, "You say", t, t["muted"], 14))
    body.append(mark(RX, 42, 24, stroke=False))
    body.append(label(RX + 34, 60, "VoiceParty types", t, t["accent"], 14))
    raw = dict(t)
    raw["ink"] = t["muted"]
    R = 18
    for (ry, h, tag, said, typed, said_h, typed_h) in rows:
        body.append(card(pad, ry, W - 2 * pad, h, t, R))
        # tinted right half, following the card's rounded corners
        x1, x2, y1, y2 = RX - 36, W - pad - 0.5, ry + 0.5, ry + h - 0.5
        body.append(f'<path d="M{x1} {f(y1)} H{f(x2-R)} Q{f(x2)} {f(y1)} {f(x2)} {f(y1+R)} V{f(y2-R)} Q{f(x2)} {f(y2)} {f(x2-R)} {f(y2)} H{x1} Z" '
                    f'fill="{t["accent_soft"]}" fill-opacity="{t["accent_soft_op"]*0.45}"/>')
        sy = ry + (h - said_h) / 2
        chip_w = tw(tag, 13, 600) + 24
        body.append(f'<rect x="{LX}" y="{f(sy)}" width="{f(chip_w)}" height="26" rx="13" fill="{t["accent_soft"]}" fill-opacity="{t["accent_soft_op"]}"/>')
        body.append(f'<text x="{f(LX+chip_w/2)}" y="{f(sy+17.5)}" text-anchor="middle" class="s" font-size="13" font-weight="600" fill="{t["accent"]}">{esc(tag)}</text>')
        for i, line in enumerate(said):
            body.append(rich_line(LX, sy + CHIP + 22 + i * lh, line, 21, raw))
        ay = ry + h / 2
        body.append(f'<path d="M{RX-92} {f(ay)} H{RX-62} M{RX-70} {f(ay-7)} L{RX-62} {f(ay)} L{RX-70} {f(ay+7)}" fill="none" '
                    f'stroke="{t["accent"]}" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"/>')
        ty = ry + (h - typed_h) / 2 + 23
        for line in typed:
            if line is None:
                ty += blank
                continue
            body.append(rich_line(RX, ty, line, 22, t, 500))
            ty += lh
    write(f"cleanup-{theme}.svg", "\n".join(body), W, H)


# ---------------------------------------------------------------- the dictation bar, state by state
def bar_states(theme):
    t = THEMES[theme]
    W, pad, gap = 1280, 40, 20
    tw_ = (W - 2 * pad - 2 * gap) / 3
    th = 214
    H = pad + th + gap + th + gap + 150 + pad
    extra = f"""<linearGradient id="tile" x1="0" y1="0" x2="0" y2="1">
    <stop offset="0" stop-color="{t['tile_a']}"/><stop offset="1" stop-color="{t['tile_b']}"/>
  </linearGradient>"""
    body = [style_block(), defs_common(t, extra)]
    body.append(f'<rect width="{W}" height="{H}" rx="28" fill="{t["canvas"]}"/>')
    body.append(f'<rect x="0.5" y="0.5" width="{W-1}" height="{H-1}" rx="27.5" fill="none" stroke="{t["frame"]}" stroke-opacity="{t["frame_op"]}"/>')
    s = 2.0
    tiles = [
        ("Hold to talk", "Hold fn while you speak; let go to insert.", pill_hold),
        ("Hands-free", "Double-tap fn (or press fn Space) and talk freely.", pill_handsfree),
        ("Command Mode", "Hold fn ⌃ to edit selected text or ask a question.", pill_command),
        ("Cleaning up", "Transcription and cleanup run on your Mac.", pill_processing),
        ("Notetaker", "Records a meeting; Stop writes the notes.", pill_notetaker),
        ("Always-on bar", "Optional: a small bar you can click to dictate.", pill_resting),
    ]
    for i, (title, desc, fn) in enumerate(tiles):
        col, row = i % 3, i // 3
        x = pad + col * (tw_ + gap)
        y = pad + row * (th + gap)
        body.append(f'<rect x="{f(x)}" y="{f(y)}" width="{f(tw_)}" height="{th}" rx="18" fill="url(#tile)"/>')
        body.append(f'<rect x="{f(x+0.5)}" y="{f(y+0.5)}" width="{f(tw_-1)}" height="{th-1}" rx="17.5" fill="none" stroke="{t["hair"]}" stroke-opacity="{t["hair_op"]}"/>')
        body.append(fn(x + tw_ / 2, y + 82, s))
        body.append(f'<text x="{f(x+tw_/2)}" y="{f(y+160)}" text-anchor="middle" class="s" font-size="19" font-weight="600" fill="{t["ink"]}">{esc(title)}</text>')
        body.append(f'<text x="{f(x+tw_/2)}" y="{f(y+189)}" text-anchor="middle" class="s" font-size="15.5" fill="{t["muted"]}">{esc(desc)}</text>')
    # the learning toast, full width
    y = pad + 2 * (th + gap)
    body.append(f'<rect x="{pad}" y="{f(y)}" width="{W-2*pad}" height="150" rx="18" fill="url(#tile)"/>')
    body.append(f'<rect x="{pad+0.5}" y="{f(y+0.5)}" width="{W-2*pad-1}" height="149" rx="17.5" fill="none" stroke="{t["hair"]}" stroke-opacity="{t["hair_op"]}"/>')
    svg, tw_toast = toast(pad + 56, y + 75, s, "Learned “Tamaro”: it's in your dictionary now", "Undo")
    body.append(svg)
    tx = pad + 56 + tw_toast + 48
    body.append(f'<text x="{f(tx)}" y="{f(y+68)}" class="s" font-size="19" font-weight="600" fill="{t["ink"]}">Learns from your fixes</text>')
    body.append(f'<text x="{f(tx)}" y="{f(y+97)}" class="s" font-size="15.5" fill="{t["muted"]}">Correct a word after dictating and</text>')
    body.append(f'<text x="{f(tx)}" y="{f(y+120)}" class="s" font-size="15.5" fill="{t["muted"]}">it joins your dictionary, with Undo.</text>')
    write(f"dictation-bar-{theme}.svg", "\n".join(body), W, int(H))


# ---------------------------------------------------------------- a meeting note
NOTE = dict(
    title="Launch sync",
    meta="Oct 1 at 10:00 AM · 32 min · with Priya, Tamaro, Sam",
    summary=["The beta build is ready; the onboarding copy is the last open item.",
             "Support wants a help page live before the launch email goes out.",
             "Testers mostly asked for a shortcuts cheat sheet."],
    decisions=["Move the launch to Thursday.", "Add the cheat sheet to the help page, not the app."],
    actions=["Priya: final onboarding copy by Tuesday", "Tamaro: draft the help page", "Sam: schedule the launch email for Thursday"],
    transcript=[("You", "0:04", "Quick launch check. Where are we on the beta?"),
                ("Others", "0:11", "The build is ready. The only open item is the onboarding copy."),
                ("You", "0:26", "Great. Can we still make Wednesday?"),
                ("Others", "0:34", "Support needs a help page first, so Thursday is safer."),
                ("You", "0:47", "Thursday it is. Tamaro, can you draft the help page?")],
)


def notetaker(theme):
    t = THEMES[theme]
    W = 1280
    body = [style_block(), defs_common(t)]
    frame_at = len(body)
    L = 56
    body.append(f'<path d="M{L+6} 50 L{L} 56 L{L+6} 62" fill="none" stroke="{t["accent"]}" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>')
    body.append(f'<text x="{L+16}" y="61" class="s" font-size="15" fill="{t["accent"]}">All notes</text>')
    body.append(f'<text x="{L}" y="118" class="r" font-size="40" fill="{t["ink"]}">{esc(NOTE["title"])}</text>')
    body.append(f'<text x="{L}" y="150" class="s" font-size="16" fill="{t["muted"]}">{esc(NOTE["meta"])}</text>')
    bw = tw("Copy as Markdown", 15, 500) + 32
    bx = W - L - bw
    body.append(f'<rect x="{f(bx)}" y="92" width="{f(bw)}" height="36" rx="10" fill="{t["well"]}" stroke="{t["hair"]}" stroke-opacity="{t["hair_op"]}"/>')
    body.append(f'<text x="{f(bx+bw/2)}" y="115.5" text-anchor="middle" class="s" font-size="15" font-weight="500" fill="{t["ink"]}">Copy as Markdown</text>')

    colw = 700
    y = 196

    def section(title, items, kind, y):
        body.append(label(L, y, title, t, t["muted"], 13))
        y += 14
        lines = []
        for it in items:
            lines.append(wrap(it, 17, colw - 80))
        h = 26 * 2 + sum(len(l) for l in lines) * 26 + (len(lines) - 1) * 10
        body.append(card(L, y, colw, h, t, 14, shadow=False))
        yy = y + 26 + 18
        for ls in lines:
            if kind == "bullet":
                body.append(f'<text x="{L+24}" y="{yy}" class="s" font-size="17" fill="{t["faint"]}">•</text>')
            else:
                body.append(f'<rect x="{L+22}" y="{yy-14}" width="15" height="15" rx="4" fill="none" stroke="{t["faint"]}" stroke-width="1.6"/>')
            for j, ln in enumerate(ls):
                body.append(f'<text x="{L+(44 if kind == "bullet" else 50)}" y="{yy + j*26}" class="s" font-size="17" fill="{t["ink"]}">{esc(ln)}</text>')
            yy += len(ls) * 26 + 10
        return y + h + 30

    y = section("Summary", NOTE["summary"], "bullet", y)
    y = section("Decisions", NOTE["decisions"], "bullet", y)
    y = section("Action items", NOTE["actions"], "box", y)

    # transcript column
    TX = L + colw + 28
    TW = W - L - TX
    body.append(label(TX, 196, "Transcript", t, t["muted"], 13))
    ty = 210
    blocks = [(sp, tm, wrap(tx, 16, TW - 118)) for sp, tm, tx in NOTE["transcript"]]
    th = 24 * 2 + sum(max(2, len(b[2])) * 23 for b in blocks) + (len(blocks) - 1) * 16
    body.append(card(TX, ty, TW, th, t, 14, shadow=False))
    yy = ty + 24 + 16
    for sp, tm, lines in blocks:
        color = t["accent"] if sp == "You" else t["ink"]
        body.append(f'<text x="{TX+22}" y="{yy}" class="s" font-size="14" font-weight="600" fill="{color}">{sp}</text>')
        body.append(f'<text x="{TX+22}" y="{yy+20}" class="s" font-size="13" fill="{t["muted"]}" style="font-variant-numeric:tabular-nums">{tm}</text>')
        for j, ln in enumerate(lines):
            body.append(f'<text x="{TX+96}" y="{yy + j*23}" class="s" font-size="16" fill="{t["ink"]}">{esc(ln)}</text>')
        yy += max(2, len(lines)) * 23 + 16
    # footnote
    fy = ty + th + 44
    body.append(lock_glyph(TX + 2, fy - 13, t["faint"], 0.85))
    body.append(f'<text x="{TX+22}" y="{fy}" class="s" font-size="14" fill="{t["muted"]}">Transcribed and summarized on this Mac.</text>')
    body.append(f'<text x="{TX+22}" y="{fy+22}" class="s" font-size="14" fill="{t["muted"]}">Nothing joins the call.</text>')
    H = int(max(y - 30, fy + 22) + 48)
    body.insert(frame_at, f'<rect width="{W}" height="{H}" rx="28" fill="{t["canvas"]}"/>'
                          f'<rect x="0.5" y="0.5" width="{W-1}" height="{H-1}" rx="27.5" fill="none" stroke="{t["frame"]}" stroke-opacity="{t["frame_op"]}"/>')
    write(f"notetaker-{theme}.svg", "\n".join(body), W, H)


CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"


def png(name, out, scale=1):
    """Renders an SVG the way GitHub shows it (inside an <img>) with headless Chrome."""
    svg = os.path.join(OUT, name)
    head = open(svg).read(300)
    w = int(head.split('width="')[1].split('"')[0])
    h = int(head.split('height="')[1].split('"')[0])
    with tempfile.TemporaryDirectory() as tmp:
        shutil.copy(svg, os.path.join(tmp, "i.svg"))
        with open(os.path.join(tmp, "i.html"), "w") as fh:
            fh.write(f'<html><body style="margin:0"><img src="i.svg" width="{w}" height="{h}" style="display:block"></body></html>')
        subprocess.run([CHROME, "--headless=new", "--disable-gpu", "--hide-scrollbars", "--default-background-color=00000000",
                        f"--force-device-scale-factor={scale}", f"--window-size={w},{h}", f"--screenshot={out}",
                        "file://" + os.path.join(tmp, "i.html")], check=True, capture_output=True)
    print("wrote", os.path.relpath(out, OUT))


if __name__ == "__main__":
    logo()
    social()
    for th in ("light", "dark"):
        hero(th)
        cleanup(th)
        bar_states(th)
        notetaker(th)
    if "--png" in sys.argv:
        png("hero-light.svg", os.path.join(OUT, "hero-light.png"), 2)
        png("hero-dark.svg", os.path.join(OUT, "hero-dark.png"), 2)
        png("social-preview.svg", os.path.join(OUT, "social-preview.png"), 1)
        github = os.path.join(OUT, "..", "..", ".github")
        os.makedirs(github, exist_ok=True)
        shutil.copy(os.path.join(OUT, "social-preview.png"), os.path.join(github, "social-preview.png"))
        print("copied social-preview.png to .github/")
