#!/usr/bin/env python3
"""Generate the Marine Sensitivity brand set: one source, every variant.

    python3 make_branding.py            # writes the SVGs and renders the PNGs
    AGENCY=MMA python3 make_branding.py # when the agency name changes, re-render

Why a generator and not hand-kept files: the set is the same three drawings
(mark, lockup, hero) in light and dark, and the agency label is a string that is
already scheduled to change (BOEM -> MMA). Hand-maintaining ten SVGs means nine
of them drift. The mark stays deliberately plain -- it has to survive 16px in a
browser tab -- and the life and the data motifs live in the bigger pieces, where
there is room to read them.
"""
import math, os, subprocess

AGENCY   = os.environ.get("AGENCY", "BOEM")          # "" for an agency-free lockup
SEA      = [("0", "#2E8FBE"), ("0.55", "#3AB2E4"), ("1", "#66CDE0")]
SPECTRAL = ["#5E4FA2","#3288BD","#66C2A5","#ABDDA4","#E6F598","#FFFFBF",
            "#FEE08B","#FDAE61","#F46D43","#D53E4F","#9E0142"]
FONT = "Avenir Next, -apple-system, Segoe UI, Helvetica, Arial, sans-serif"

def theme(dark):
    return dict(ring="#DDE7EC" if dark else "#2F4858",
                sky ="#0E1B22" if dark else "#FFFFFF",
                word="#FFFFFF" if dark else "#20343F",
                sub ="#9DB4C0" if dark else "#5A7684",
                swell="0.22"   if dark else "0.16")

def grad(id_, stops, x1=0, y1=1, x2=1, y2=0):
    s = "".join(f'<stop offset="{o}" stop-color="{c}"/>' for o, c in stops)
    return f'<linearGradient id="{id_}" x1="{x1}" y1="{y1}" x2="{x2}" y2="{y2}">{s}</linearGradient>'

# ---- marine life, as silhouettes -------------------------------------------
# What the toolkit is actually about. The fluke is the one whale silhouette that
# reads at a glance and at low opacity; the turtle is drawn from above because
# that is how the app maps it, and because the leatherback is its default taxon.
FLUKE_STOCK = "M110,140 C110,190 107,222 105,258 L145,258 C143,222 140,190 140,140 Z"
FLUKE = ("M0,52 C50,44 98,78 125,122 C152,78 200,44 250,52 "
         "C214,92 176,122 155,152 C142,146 132,152 125,168 "
         "C118,152 108,146 95,152 C74,122 36,92 0,52 Z")
TURTLE_PARTS = [
    '<ellipse cx="60" cy="66" rx="36" ry="44"/>',
    '<circle cx="60" cy="16" r="13"/>',
    '<path d="M28,36 C8,26 -6,30 -10,44 C-4,52 12,52 30,46 Z"/>',
    '<path d="M92,36 C112,26 126,30 130,44 C124,52 108,52 90,46 Z"/>',
    '<path d="M32,96 C16,102 6,114 8,128 C18,130 32,120 40,106 Z"/>',
    '<path d="M88,96 C104,102 114,114 112,128 C102,130 88,120 80,106 Z"/>',
]
FISH_BODY = "M0,0 C10,-8 26,-9 38,-2 C44,2 44,6 38,10 C26,17 10,16 0,8 Z"
FISH_TAIL = "M0,4 L-14,-6 L-11,4 L-14,14 Z"

def whale(x, y, scale, opacity, fill="#DFF3FB"):
    t = f"translate({x},{y}) scale({scale})"
    return (f'<g transform="{t}" fill="{fill}" opacity="{opacity}">'
            f'<path d="{FLUKE_STOCK}"/><path d="{FLUKE}"/></g>')

def turtle(x, y, scale, opacity, fill="#DFF3FB"):
    return (f'<g transform="translate({x},{y}) scale({scale})" fill="{fill}" opacity="{opacity}">'
            + "".join(TURTLE_PARTS) + "</g>")

def fish(x, y, scale, opacity, flip=False, fill="#DFF3FB"):
    t = f"translate({x},{y}) scale({-scale if flip else scale},{scale})"
    return (f'<g transform="{t}" fill="{fill}" opacity="{opacity}">'
            f'<path d="{FISH_BODY}"/><path d="{FISH_TAIL}"/></g>')

# ---- the mark ---------------------------------------------------------------
def mark(dark=False):
    t = theme(dark)
    return f'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512" width="512" height="512"
     role="img" aria-label="Marine Sensitivity Toolkit">
  <title>Marine Sensitivity Toolkit</title>
  <defs>{grad("sea", SEA)}<clipPath id="disc"><circle cx="256" cy="256" r="228"/></clipPath></defs>
  <circle cx="256" cy="256" r="228" fill="{t['sky']}"/>
  <path clip-path="url(#disc)" fill="url(#sea)"
        d="M-20,330 C 80,372 168,330 248,258 C 316,197 404,168 532,150 L 532,532 L -20,532 Z"/>
  <path clip-path="url(#disc)" fill="#FFFFFF" opacity="{t['swell']}"
        d="M-20,392 C 90,424 190,388 268,326 C 338,270 430,244 532,232 L 532,286
           C 430,300 344,326 276,382 C 196,448 84,470 -20,436 Z"/>
  <circle cx="256" cy="256" r="228" fill="none" stroke="{t['ring']}" stroke-width="18"/>
</svg>'''

# ---- the lockup: mark plus wordmark ----------------------------------------
def lockup(dark=False, agency=AGENCY):
    t = theme(dark)
    sub = f"TOOLKIT &#183; {agency}" if agency else "TOOLKIT"
    return f'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1200 300" width="1200" height="300"
     role="img" aria-label="Marine Sensitivity Toolkit">
  <title>Marine Sensitivity Toolkit</title>
  <defs>{grad("sea", SEA)}<clipPath id="disc"><circle cx="150" cy="150" r="118"/></clipPath></defs>
  <circle cx="150" cy="150" r="118" fill="{t['sky']}"/>
  <path clip-path="url(#disc)" fill="url(#sea)"
        d="M20,188 C72,210 118,188 159,150 C194,118 240,103 305,93 L305,300 L20,300 Z"/>
  <path clip-path="url(#disc)" fill="#FFFFFF" opacity="{t['swell']}"
        d="M20,220 C77,237 129,218 169,186 C205,157 253,143 305,137 L305,165
           C253,172 208,185 173,214 C132,248 74,259 20,241 Z"/>
  <!-- no creature inside this disc: at lockup size it reads as a smudge. The
       mark stays plain everywhere; the life lives in the hero, where it is
       legible. -->
  <circle cx="150" cy="150" r="118" fill="none" stroke="{t['ring']}" stroke-width="10"/>
  <g font-family="{FONT}">
    <text x="312" y="132" font-size="100" font-weight="600" fill="{t['word']}"
          dominant-baseline="middle">Marine Sensitivity</text>
    <text x="316" y="232" font-size="36" font-weight="500" letter-spacing="7" fill="{t['sub']}">{sub}</text>
  </g>
</svg>'''

# ---- the hero ---------------------------------------------------------------
def hero(dark=True, agency=AGENCY):
    t = theme(dark)
    sub = f"TOOLKIT &#183; {agency}" if agency else "TOOLKIT"
    bg  = ('<linearGradient id="deep" x1="0" y1="0" x2="1" y2="1">'
           '<stop offset="0" stop-color="#0B1A22"/><stop offset="1" stop-color="#173B4B"/></linearGradient>'
           if dark else
           '<linearGradient id="deep" x1="0" y1="0" x2="1" y2="1">'
           '<stop offset="0" stop-color="#F4F8FA"/><stop offset="1" stop-color="#DCE9EF"/></linearGradient>')
    tag = "#C9DAE3" if dark else "#3D5A69"
    # the 0.05 degree cell grid, riding the crest and fading at both ends
    def cell(i):
        x = 40 + i * 34.0
        y = 556 - 150 * math.sin(i / 45 * math.pi * 0.8) ** 1.5
        o = 0.10 + 0.30 * math.sin(i / 45 * math.pi)
        # the text block owns 380..1060; the grid dives under it rather than through it
        if 360 < x < 1080 and y < 520:
            return ""
        return (f'<rect x="{x:.1f}" y="{y:.1f}" width="22" height="22" rx="2" '
                f'fill="#BFEAF7" opacity="{o:.2f}"/>')
    cells = "\n    ".join(filter(None, (cell(i) for i in range(46))))
    spectral = grad("spectral", [(f"{i/(len(SPECTRAL)-1):.3f}", c) for i, c in enumerate(SPECTRAL)],
                    x1=0, y1=0, x2=1, y2=0)
    return f'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1600 640" width="1600" height="640"
     role="img" aria-label="Marine Sensitivity Toolkit">
  <title>Marine Sensitivity Toolkit</title>
  <desc>The wave mark, the 0.05 degree cell grid every distribution is resampled onto,
        the Spectral ramp the score maps use, and the animals being scored.</desc>
  <defs>
    {bg}{grad("sea", SEA)}{spectral}
    <clipPath id="disc"><circle cx="212" cy="300" r="132"/></clipPath>
    <clipPath id="frame"><rect x="0" y="0" width="1600" height="640"/></clipPath>
  </defs>
  <rect width="1600" height="640" fill="url(#deep)"/>
  <g clip-path="url(#frame)" stroke="#7FB6CC" stroke-width="1" opacity="0.22">
    <path d="M0,140 H1600 M0,300 H1600 M0,460 H1600"/>
    <path d="M300,0 V640 M600,0 V640 M900,0 V640 M1200,0 V640 M1500,0 V640"/>
  </g>
  <g clip-path="url(#frame)">
    <path fill="url(#sea)" opacity="0.95"
          d="M-20,520 C 260,586 520,520 780,452 C 1040,384 1320,352 1620,346 L1620,660 L-20,660 Z"/>
    <path fill="#FFFFFF" opacity="0.10"
          d="M-20,566 C 280,624 540,566 800,500 C 1060,434 1330,404 1620,398 L1620,436
             C 1330,442 1070,472 812,538 C 552,604 280,660 -20,602 Z"/>
    {cells}
    {whale(1140, 300, 0.62, 0.42)}
    {turtle(620, 516, 0.68, 0.34)}
    {fish(1425, 545, 1.6, 0.40)}
    {fish(1492, 585, 1.2, 0.32)}
    {fish(1392, 600, 1.0, 0.28)}
  </g>
  <circle cx="212" cy="300" r="132" fill="{t['sky']}"/>
  <path clip-path="url(#disc)" fill="url(#sea)"
        d="M60,342 C118,368 170,342 216,300 C255,264 306,247 380,236 L380,470 L60,470 Z"/>
  <path clip-path="url(#disc)" fill="#FFFFFF" opacity="{t['swell']}"
        d="M60,378 C124,397 182,376 227,340 C267,308 321,292 380,286 L380,317
           C321,325 271,339 232,372 C186,410 121,422 60,402 Z"/>
  <circle cx="212" cy="300" r="132" fill="none" stroke="{t['ring']}" stroke-width="11"/>
  <g font-family="{FONT}">
    <text x="400" y="252" font-size="112" font-weight="600" fill="{t['word']}">Marine Sensitivity</text>
    <text x="404" y="316" font-size="38" font-weight="500" letter-spacing="7.5" fill="{t['sub']}">{sub}</text>
    <rect x="404" y="352" width="620" height="12" rx="6" fill="url(#spectral)"/>
    <text x="404" y="424" font-size="34" fill="{tag}">Species distributions and extinction risk,</text>
    <text x="404" y="470" font-size="34" fill="{tag}">scored across US ocean waters.</text>
  </g>
</svg>'''

def badge(dark=False):
    "the mark with breathing room, for small inline placements"
    inner = mark(dark).split("\n", 2)[2].rsplit("</svg>", 1)[0]
    return ('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 600 600" width="600" height="600"'
            ' role="img" aria-label="Marine Sensitivity Toolkit">\n'
            '  <title>Marine Sensitivity Toolkit</title>\n'
            f'  <g transform="translate(44,44)">{inner}</g>\n</svg>')

files = {
    "mst-mark-badge.svg": badge(dark=False),
    "mst-mark.svg":      mark(dark=False),
    "mst-mark-dark.svg": mark(dark=True),
    "mst-logo.svg":      lockup(dark=False),
    "mst-logo-dark.svg": lockup(dark=True),
    "mst-hero.svg":      hero(dark=True),
    "mst-hero-light.svg":hero(dark=False),
}
for name, svg in files.items():
    open(name, "w").write(svg)

# PNGs for anywhere a font or an SVG cannot be relied on (Cloudflare's login page,
# slide decks, GitHub READMEs)
renders = [("mst-mark.svg", "mst-mark-512.png", 512, 512),
           ("mst-mark-dark.svg", "mst-mark-dark-512.png", 512, 512),
           ("mst-mark.svg", "mst-mark-192.png", 192, 192),
           # a padded square for places that set the logo inline beside text --
           # Cloudflare Access's login header is one: it scales the image to about
           # 30px tall, so a wide lockup becomes an unreadable smear and the mark
           # alone is what works. The padding keeps the ring off the wordmark.
           ("mst-mark-badge.svg", "mst-mark-badge-256.png", 256, 256),
           ("mst-logo.svg", "mst-logo.png", 1200, 300),
           ("mst-logo-dark.svg", "mst-logo-dark.png", 1200, 300),
           ("mst-hero.svg", "mst-hero.png", 1600, 640),
           ("mst-hero-light.svg", "mst-hero-light.png", 1600, 640)]
for src, out, w, h in renders:
    subprocess.run(["rsvg-convert", "-w", str(w), "-h", str(h), src, "-o", out], check=True)

# a favicon from the same vector, sharper than the 2024 original at every size
subprocess.run(["magick", "-background", "none", "mst-mark.svg",
                "-define", "icon:auto-resize=16,32,48,64", "favicon.ico"], check=True)
print("wrote", len(files), "svgs +", len(renders), "pngs + favicon.ico  (AGENCY=%r)" % AGENCY)
