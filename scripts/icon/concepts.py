import numpy as np
from glass import *

def ellipse_point(cx, cy, a, b, tilt, t):
    x, y = a * np.cos(t), b * np.sin(t)
    c, s = np.cos(tilt), np.sin(tilt)
    return cx + x * c - y * s, cy + x * s + y * c

def orbit_arrow(cx, cy, a, b, tilt, w, t_gap0, t_gap1, head_len=0.085, head_w=0.07):
    """Tilted elliptical ring with a gap and an arrow head; returns (back_sdf, front_sdf)."""
    ring = stroke(sd_ellipse(cx, cy, a, b, tilt), w)
    x, y = rot(cx, cy, tilt)
    t = np.arctan2(y / b, x / a)
    in_gap = (t > t_gap0) & (t < t_gap1)
    ring = np.where(in_gap, 1.0, ring)
    # arrow head at t_gap0 pointing along +t
    p0 = np.array(ellipse_point(cx, cy, a, b, tilt, t_gap0))
    p1 = np.array(ellipse_point(cx, cy, a, b, tilt, t_gap0 + 0.01))
    tan = (p1 - p0) / np.linalg.norm(p1 - p0)
    nrm = np.array([-tan[1], tan[0]])
    base = p0 - tan * 0.01
    head = sd_polygon([base + nrm * head_w, base - nrm * head_w, base + tan * head_len])
    arrow = np.minimum(ring, head)
    front = np.where(y >= 0, arrow, 1.0)
    back = np.where(y < 0, arrow, 1.0)
    return back, front

def camera_orbit(path):
    img = linear_bg('#3d7bff', '#4b2fd6', 1.0)
    img = radial_light(img, 0.30, 0.18, 0.32, '#a9d2ff', 0.35)
    back, front = orbit_arrow(0.5, 0.53, 0.43, 0.15, -0.28, 0.045, -0.55, 0.05)
    img = glass(img, back, tint='#e6f0ff', opacity=0.35, rim=0.6, shadow=False)
    body = sd_box(0.5, 0.53, 0.25, 0.17, 0.06)
    bump = sd_box(0.5, 0.35, 0.08, 0.05, 0.025)
    cam = smooth_union(body, bump, 0.02)
    img = glass(img, cam, tint='#ffffff', opacity=0.62, rim=1.0, rim_w=0.008, sheen=0.12)
    lens_outer = sd_circle(0.5, 0.54, 0.115)
    img = glass(img, lens_outer, tint='#1a2f7a', opacity=0.85, rim=0.8, rim_w=0.006, sheen=0.05, shadow=False)
    lens_inner = sd_circle(0.5, 0.54, 0.068)
    img = glass(img, lens_inner, tint='#4b86ff', opacity=0.7, rim=0.6, rim_w=0.005, sheen=0.25, shadow=False,
                highlight=(0.478, 0.52, 0.026, 0.014, -0.6, 0.8))
    flash = sd_circle(0.67, 0.44, 0.018)
    img = glossy(img, flash, '#ff8a1f', shadow=False)
    img = glass(img, front, tint='#ffffff', opacity=0.42, rim=0.9, shadow=True)
    return finish(img, path)

def aperture360(path):
    img = linear_bg('#f6f8ff', '#cdd8ff', 1.0)
    img = radial_light(img, 0.5, 0.2, 0.35, '#ffffff', 0.35)
    cx, cy, R, r_in = 0.5, 0.5, 0.27, 0.075
    back, front = orbit_arrow(cx, cy, 0.42, 0.13, -0.25, 0.03, -0.45, 0.10, head_len=0.06, head_w=0.05)
    img = glass(img, back, tint='#6f86d6', opacity=0.55, rim=0.5, shadow=False)
    tints = ['#2ec5ff', '#3d7bff', '#6a5cff', '#a35cff', '#ff6aa8', '#ff9a3d']
    circle = sd_circle(cx, cy, R)
    img = drop_shadow(img, circle, offset=(0, 0.02), blur_px=40, opacity=0.25, color='#28306e')
    # Spiral aperture: sectors twisted with radius -> curved blades around a round opening.
    r = np.hypot(U - cx, V - cy)
    twist = 1.1
    ang = (np.arctan2(V - cy, U - cx) + twist * (1 - r / R)) % (2 * np.pi)
    sector = np.floor(ang / (np.pi / 3)).astype(int)
    local = ang - sector * (np.pi / 3)
    edge = np.minimum(local, np.pi / 3 - local) * r          # distance to the blade boundary (approx.)
    gap = 0.007
    for k in range(6):
        blade = np.maximum(np.maximum(circle, r_in - r), -(edge - gap / 2))
        blade = np.where(sector == k, blade, 1.0)
        img = glass(img, blade, tint=tints[k], opacity=0.85, rim=0.7, rim_w=0.005, sheen=0.18, shadow=False)
    img = glass(img, front, tint='#5b72cc', opacity=0.7, rim=0.6, shadow=True)
    return finish(img, path)

def lens_globe(path):
    img = linear_bg('#1e3a9a', '#070c2a', 1.0)
    img = radial_light(img, 0.5, 0.42, 0.33, '#4f7dff', 0.45)
    barrel = sd_circle(0.5, 0.5, 0.33)
    img = glass(img, barrel, tint='#c9d6f5', opacity=0.55, rim=1.0, rim_w=0.008, sheen=0.15)
    ring2 = sd_circle(0.5, 0.5, 0.275)
    img = glass(img, ring2, tint='#0b1238', opacity=0.9, rim=0.5, rim_w=0.005, sheen=0.02, shadow=False)
    R = 0.24
    elem = sd_circle(0.5, 0.5, R)
    img = glass(img, elem, tint='#2a63ff', opacity=0.55, rim=0.8, rim_w=0.006, sheen=0.25, shadow=False)
    inside = cov(elem)
    line = '#cfe0ff'
    for lat in (0.0, 0.5, -0.5):
        cy = 0.5 - R * np.sin(lat); a = R * np.cos(lat); b = 0.06 * np.cos(lat)
        img = over(img, hexc(line), cov(stroke(sd_ellipse(0.5, cy, a, b), 0.006)) * inside * (0.6 if lat == 0 else 0.4))
    for aa in (0.004, R * 0.55):
        img = over(img, hexc(line), cov(stroke(sd_ellipse(0.5, 0.5, aa, R), 0.006)) * inside * 0.4)
    img = img + (cov(sd_ellipse(0.42, 0.37, 0.08, 0.035, -0.7), soft=60) * inside)[..., None] * 0.45
    dot = sd_circle(0.605, 0.405, 0.04)
    img = glossy(img, dot, '#ff8a1f')
    return finish(img, path)

def lens_orbit(path):
    img = linear_bg('#16b9d0', '#2350e8', 1.0)
    img = radial_light(img, 0.3, 0.2, 0.32, '#d6fffb', 0.3)
    tilt = -0.3
    ring = stroke(sd_ellipse(0.5, 0.52, 0.42, 0.14, tilt), 0.035)
    x, y = rot(0.5, 0.52, tilt)
    img = glass(img, np.where(y < 0, ring, 1.0), tint='#ffffff', opacity=0.4, rim=0.5, shadow=False)
    barrel = sd_circle(0.5, 0.52, 0.22)
    img = glass(img, barrel, tint='#ffffff', opacity=0.6, rim=1.0, rim_w=0.008, sheen=0.12)
    lens = sd_circle(0.5, 0.52, 0.15)
    img = glass(img, lens, tint='#0d1f5c', opacity=0.85, rim=0.7, rim_w=0.006, sheen=0.05, shadow=False)
    inner = sd_circle(0.5, 0.52, 0.085)
    img = glass(img, inner, tint='#4b86ff', opacity=0.7, rim=0.6, rim_w=0.005, sheen=0.25, shadow=False,
                highlight=(0.472, 0.495, 0.032, 0.018, -0.6, 0.8))
    img = glass(img, np.where(y >= 0, ring, 1.0), tint='#ffffff', opacity=0.5, rim=0.9, shadow=True)
    px, py = ellipse_point(0.5, 0.52, 0.42, 0.14, tilt, 0.55)
    img = glossy(img, sd_circle(px, py, 0.045), '#ff8a1f')
    return finish(img, path)

if __name__ == '__main__':
    for name, fn in [('6-camera-orbit', camera_orbit), ('7-aperture360', aperture360),
                     ('8-lens-globe', lens_globe), ('9-lens-orbit', lens_orbit)]:
        fn(f'{name}.png'); print('rendered', name)
