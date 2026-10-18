"""Draws the app icon: a record dot wrapped in a ribbon of ink that trails off into a squiggle,
on paper. Writes icon-rounded.svg, icon-square.svg and icon-macos.svg into the given folder."""
import math, sys


def squircle(size=1024, n=5, steps=720):
    """Apple's continuous-corner icon shape: a superellipse."""
    h = size / 2
    pts = []
    for i in range(steps):
        t = 2 * math.pi * i / steps
        c, s = math.cos(t), math.sin(t)
        pts.append(f"{h + h * math.copysign(abs(c) ** (2 / n), c):.1f},{h + h * math.copysign(abs(s) ** (2 / n), s):.1f}")
    return "M" + " L".join(pts) + " Z"


def bezier(p0, p1, p2, p3, n):
    pts = []
    for i in range(1, n + 1):
        t = i / n
        a = ((1 - t) ** 3, 3 * (1 - t) ** 2 * t, 3 * (1 - t) * t ** 2, t ** 3)
        pts.append(tuple(sum(a[k] * p[j] for k, p in enumerate((p0, p1, p2, p3))) for j in (0, 1)))
    return pts


def ribbon():
    """The ribbon's outline. Its centerline goes around the dot from the top right (over the
    top, down the left, under it) and off into the squiggle; thin where it starts, then even."""
    cx, cy, r, ring = 418, 500, 284, 241
    line = [(cx + r * math.cos(a), cy + r * math.sin(a)) for a in (math.radians(-28 - i * 232 / (ring - 1)) for i in range(ring))]
    p0, a = line[-1], math.radians(100)
    line += bezier(p0, (p0[0] + 150 * math.sin(a), p0[1] - 150 * math.cos(a)), (690, 640), (758, 586), 40)
    line += bezier(line[-1], (800, 552), (812, 600), (800, 660), 24)
    line += bezier(line[-1], (790, 712), (812, 748), (850, 712), 24)
    line += bezier(line[-1], (890, 676), (930, 628), (968, 598), 30)
    n = len(line)

    def width(i):
        if i >= ring:
            return 74 - 12 * (i - ring) / (n - ring)
        u = i / (ring - 1)
        return 6 + 86 * math.sin(min(1, u / 0.62) * math.pi / 2) - 18 * max(0, u - 0.62) / 0.38

    left, right = [], []
    for i, (x, y) in enumerate(line):
        (ax, ay), (bx, by) = line[max(0, i - 1)], line[min(n - 1, i + 1)]
        l = math.hypot(bx - ax, by - ay) or 1
        nx, ny, w = -(by - ay) / l, (bx - ax) / l, width(i) / 2
        left.append((x + nx * w, y + ny * w))
        right.append((x - nx * w, y - ny * w))

    def cap(c, w, frm):
        a0 = math.atan2(frm[1] - c[1], frm[0] - c[0])
        return [(c[0] + w * math.cos(a0 - math.pi * k / 16), c[1] + w * math.sin(a0 - math.pi * k / 16)) for k in range(1, 16)]

    pts = left + cap(line[-1], width(n - 1) / 2, left[-1]) + right[::-1] + cap(line[0], width(0) / 2, right[0])
    return "M" + " L".join(f"{x:.1f},{y:.1f}" for x, y in pts) + " Z"


def sparkle(cx, cy, r):
    k = r * 0.22
    return (f"M{cx},{cy - r} C{cx + k},{cy - k} {cx + k},{cy - k} {cx + r},{cy} "
            f"C{cx + k},{cy + k} {cx + k},{cy + k} {cx},{cy + r} "
            f"C{cx - k},{cy + k} {cx - k},{cy + k} {cx - r},{cy} "
            f"C{cx - k},{cy - k} {cx - k},{cy - k} {cx},{cy - r} Z")


def icon(rounded):
    shape = squircle() if rounded else "M0,0 H1024 V1024 H0 Z"
    return f'''
  <defs>
    <clipPath id="shape"><path d="{shape}"/></clipPath>
    <linearGradient id="paper" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#fdf8f0"/><stop offset="1" stop-color="#f3e9da"/>
    </linearGradient>
    <radialGradient id="dot" cx=".4" cy=".35" r=".75">
      <stop offset="0" stop-color="#ff7a5c"/><stop offset=".7" stop-color="#ff5240"/><stop offset="1" stop-color="#ec3f33"/>
    </radialGradient>
    <linearGradient id="ink" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0" stop-color="#2d3250"/><stop offset="1" stop-color="#1e2136"/>
    </linearGradient>
    <filter id="lift" x="-20%" y="-20%" width="140%" height="150%">
      <feGaussianBlur in="SourceAlpha" stdDeviation="10"/><feOffset dy="12" result="b"/>
      <feFlood flood-color="#7a5a3c" flood-opacity=".22"/><feComposite in2="b" operator="in"/>
      <feMerge><feMergeNode/><feMergeNode in="SourceGraphic"/></feMerge>
    </filter>
  </defs>
  <g clip-path="url(#shape)">
    <rect width="1024" height="1024" fill="url(#paper)"/>
    <path d="{shape}" fill="none" stroke="#e2d4bf" stroke-width="6"/>

    <!-- the record dot, like a sticker -->
    <g filter="url(#lift)"><circle cx="436" cy="500" r="190" fill="url(#dot)"/></g>
    <path d="M334,410 C352,368 392,342 436,338" fill="none" stroke="#fff" stroke-opacity=".85" stroke-width="30" stroke-linecap="round"/>
    <circle cx="318" cy="452" r="15" fill="#fff" fill-opacity=".85"/>

    <!-- the ribbon of ink -->
    <g filter="url(#lift)"><path d="{ribbon()}" fill="url(#ink)"/></g>

    <!-- a little sparkle where it starts -->
    <path d="{sparkle(770, 280, 54)}" fill="#ffc53d"/>
    <path d="{sparkle(842, 382, 24)}" fill="#ffc53d"/>
  </g>'''


def svg(kind):
    """rounded: the icon shape on a clear background · square: full bleed (iOS rounds it) ·
    macos: Apple's grid, the shape at 824 px on a 1024 canvas with a shadow."""
    body = icon(kind != "square")
    if kind == "macos":
        body = f'''
  <defs><filter id="tile" x="-10%" y="-10%" width="120%" height="125%">
    <feGaussianBlur in="SourceAlpha" stdDeviation="10"/><feOffset dy="10"/>
    <feComponentTransfer><feFuncA type="linear" slope=".35"/></feComponentTransfer>
    <feMerge><feMergeNode/><feMergeNode in="SourceGraphic"/></feMerge>
  </filter></defs>
  <g filter="url(#tile)"><g transform="translate(100 100) scale(.8046875)">{body}</g></g>'''
    return f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024">{body}\n</svg>\n'


for kind in ("rounded", "square", "macos"):
    with open(f"{sys.argv[1]}/icon-{kind}.svg", "w") as f:
        f.write(svg(kind))
