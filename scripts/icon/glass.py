"""Tiny SDF renderer for Liquid-Glass-style app icon concepts."""
import numpy as np
from PIL import Image, ImageFilter

N = 2048                      # render at 2x, downsample to 1024
PX = 1.0 / N
yy, xx = np.mgrid[0:N, 0:N]
U = (xx + 0.5) / N
V = (yy + 0.5) / N

def hexc(h):
    h = h.lstrip('#'); return np.array([int(h[i:i + 2], 16) / 255 for i in (0, 2, 4)])

# ---------- signed distance functions (negative inside) ----------
def sd_circle(cx, cy, r):
    return np.hypot(U - cx, V - cy) - r

def rot(cx, cy, ang):
    c, s = np.cos(ang), np.sin(ang)
    x, y = U - cx, V - cy
    return x * c + y * s, -x * s + y * c

def sd_ellipse(cx, cy, a, b, ang=0.0):
    x, y = rot(cx, cy, ang)
    k = np.hypot(x / a, y / b)
    # first-order distance approximation, good enough for thick strokes
    g = np.hypot(x / (a * a), y / (b * b)) + 1e-9
    return k * (k - 1) / g

def sd_box(cx, cy, hw, hh, r, ang=0.0):
    x, y = rot(cx, cy, ang)
    qx, qy = np.abs(x) - (hw - r), np.abs(y) - (hh - r)
    return np.hypot(np.maximum(qx, 0), np.maximum(qy, 0)) + np.minimum(np.maximum(qx, qy), 0) - r

def stroke(d, w):
    return np.abs(d) - w / 2

def cov(d, soft=1.0):
    return np.clip(0.5 - d / (PX * soft), 0, 1)

# ---------- image helpers ----------
def _box(a, r, axis):
    if r < 1: return a
    pad = [(0, 0)] * a.ndim
    pad[axis] = (r + 1, r)
    c = np.cumsum(np.pad(a, pad, mode='edge'), axis=axis)
    n = a.shape[axis]
    hi = np.take(c, np.arange(2 * r + 1, 2 * r + 1 + n), axis=axis)
    lo = np.take(c, np.arange(0, n), axis=axis)
    return (hi - lo) / (2 * r + 1)

def blur(img, sigma_px):
    """Gaussian approximation: three box blurs per axis."""
    r = max(1, int(round((np.sqrt(12 * sigma_px * sigma_px / 3 + 1) - 1) / 2)))
    out = img.astype(np.float64)
    for _ in range(3):
        out = _box(out, r, 0)
        out = _box(out, r, 1)
    return out

def over(img, color, a):
    a = a[..., None] if a.ndim == 2 else a
    return img * (1 - a) + color * a

def linear_bg(top, bottom, gamma=1.0):
    t = (V ** gamma)[..., None]
    return hexc(top) * (1 - t) + hexc(bottom) * t

def radial_light(img, cx, cy, r, color, strength):
    g = np.exp(-((U - cx) ** 2 + (V - cy) ** 2) / (2 * r * r))[..., None]
    return img + g * hexc(color) * strength

def normals(d):
    gy, gx = np.gradient(d)
    n = np.hypot(gx, gy) + 1e-12
    return gx / n, gy / n

# ---------- materials ----------
def drop_shadow(img, d, offset=(0, 0.018), blur_px=40, opacity=0.30, color='#000814'):
    a = cov(d)
    a = np.roll(np.roll(a, int(offset[1] * N), axis=0), int(offset[0] * N), axis=1)
    a = blur(a[..., None], blur_px)[..., 0] * opacity
    return over(img, hexc(color), a)

def glass(img, d, tint='#ffffff', opacity=0.22, frost=26, rim=0.9, rim_w=0.006, sheen=0.16,
          light=(-0.55, -0.83), shadow=True, highlight=None):
    """Frosted translucent glass: blurred backdrop + tint, top sheen, lit rim, specular."""
    if shadow:
        img = drop_shadow(img, d)
    a = cov(d)
    back = blur(img, frost)
    body = back * (1 - opacity) + hexc(tint) * opacity
    # vertical sheen inside the shape (lighter at the top)
    ys = np.where(a > 0, V, np.nan)
    top, bot = np.nanmin(ys), np.nanmax(ys)
    t = np.clip((V - top) / max(bot - top, 1e-6), 0, 1)[..., None]
    body = body + sheen * (1 - t) ** 2
    out = over(img, body, a)
    # rim light: thin bright band just inside the edge, stronger facing the light
    nx, ny = normals(d)
    facing = np.clip(-(nx * light[0] + ny * light[1]), 0, 1)
    back_facing = np.clip((nx * light[0] + ny * light[1]), 0, 1)
    band = np.exp(-((d + rim_w * 0.6) / rim_w) ** 2) * a
    out = out + band[..., None] * (rim * (0.25 + 0.75 * facing) + 0.35 * rim * back_facing)[..., None]
    if highlight is not None:
        hx, hy, ha, hb, hang, hs = highlight
        h = cov(sd_ellipse(hx, hy, ha, hb, hang), soft=60) * a
        out = out + h[..., None] * hs
    return out

def glossy(img, d, base, light_color='#ffffff', shadow=True):
    """Opaque glossy material (e.g. the orange capture dot)."""
    if shadow:
        img = drop_shadow(img, d, offset=(0, 0.012), blur_px=26, opacity=0.35)
    a = cov(d)
    nx, ny = normals(d)
    ys = np.where(a > 0, V, np.nan)
    top, bot = np.nanmin(ys), np.nanmax(ys)
    t = np.clip((V - top) / max(bot - top, 1e-6), 0, 1)[..., None]
    col = hexc(base) * (1.15 - 0.35 * t)
    out = over(img, col, a)
    band = np.exp(-((d + 0.004) / 0.004) ** 2) * a
    out = out + band[..., None] * 0.35
    return out

def finish(img, path):
    img = np.clip(img, 0, 1)
    im = Image.fromarray((img * 255 + 0.5).astype(np.uint8)).resize((1024, 1024), Image.LANCZOS)
    im.save(path)
    return im

def sd_polygon(pts):
    """Exact SDF of a closed polygon (Inigo Quilez), points in normalized coords."""
    pts = [np.array(p, dtype=float) for p in pts]
    d = (U - pts[0][0]) ** 2 + (V - pts[0][1]) ** 2
    s = np.ones_like(U)
    n = len(pts)
    for i in range(n):
        j = (i - 1) % n
        e = pts[j] - pts[i]
        wx, wy = U - pts[i][0], V - pts[i][1]
        t = np.clip((wx * e[0] + wy * e[1]) / (e @ e), 0, 1)
        bx, by = wx - e[0] * t, wy - e[1] * t
        d = np.minimum(d, bx * bx + by * by)
        c1 = V >= pts[i][1]
        c2 = V < pts[j][1]
        c3 = e[0] * wy > e[1] * wx
        flip = (c1 & c2 & c3) | (~c1 & ~c2 & ~c3)
        s = np.where(flip, -s, s)
    return s * np.sqrt(d)

def smooth_union(a, b, k=0.01):
    h = np.clip(0.5 + 0.5 * (b - a) / k, 0, 1)
    return b * (1 - h) + a * h - k * h * (1 - h)
