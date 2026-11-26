import sys
from PIL import Image, ImageDraw, ImageFilter
import numpy as np

src = Image.open(sys.argv[1]).convert("RGB")
out_path = sys.argv[2]
S = 1024
a = np.asarray(src.resize((S, S), Image.LANCZOS)).astype(np.float64) / 255.0
yy, xx = np.mgrid[0:S, 0:S] / (S - 1.0)

# 1) Smooth model of the old background: quadratic per channel, robustly fitted on
#    pixels that look like background (dark, unsaturated-ish navy).
lum = a.mean(2)
sat = a.max(2) - a.min(2)
cand = (lum < 0.22) & (sat < 0.35)
# exclude the lens area (centre) – it is dark too
r = np.hypot(xx - 0.5, yy - 0.5)
cand &= r > 0.40
X = np.stack([np.ones_like(xx), xx, yy, xx * xx, yy * yy, xx * yy], -1)
mask = cand.copy()
for _ in range(4):
    A = X[mask]
    coefs = [np.linalg.lstsq(A, a[..., c][mask], rcond=None)[0] for c in range(3)]
    bg_old = np.stack([X @ co for co in coefs], -1)
    res = np.abs(a - bg_old).sum(2)
    mask = cand & (res < np.percentile(res[cand], 80))
residual = a - bg_old

# 2) Keep only clear deviations from the background (lens, ribbon, glow, shadows); the
#    faint outline of the old rounded tile and the top-edge line fall below threshold.
mag = np.abs(residual).max(2)
alpha = np.clip((mag - 0.025) / 0.045, 0, 1)
alpha = np.asarray(Image.fromarray((alpha * 255).astype(np.uint8)).filter(ImageFilter.GaussianBlur(1.2))) / 255.0
# The artwork never reaches the outer border; the old rounded tile's edge lives there.
# Inside a rounded rectangle inset by 6% keep everything, outside only strong artwork.
inner = Image.new("L", (S, S), 0)
inset = int(S * 0.06)
ImageDraw.Draw(inner).rounded_rectangle([inset, inset, S - 1 - inset, S - 1 - inset], radius=int(S * 0.17), fill=255)
inner = np.asarray(inner.filter(ImageFilter.GaussianBlur(8))) / 255.0
strong = np.clip((mag - 0.15) / 0.1, 0, 1)
alpha = alpha * np.maximum(inner, strong)
# Hard-protect the lens disk so its dark interior stays intact.
lens = (r < 0.335).astype(np.float64)
lens = np.asarray(Image.fromarray((lens * 255).astype(np.uint8)).filter(ImageFilter.GaussianBlur(6))) / 255.0
alpha = np.maximum(alpha, lens)
fg_res = residual * alpha[..., None]

# 3) Shrink the artwork a little to sit inside Apple's icon grid.
scale = float(sys.argv[3]) if len(sys.argv) > 3 else 0.9
def shrink(img3):
    ims = []
    for c in range(img3.shape[2]):
        ch = Image.fromarray(((img3[..., c] + 1) * 32767.5).clip(0, 65535).astype(np.uint16).astype(np.int32), "I")
        ims.append(ch)
    n = int(S * scale)
    o = (S - n) // 2
    res = np.zeros_like(img3)
    for c, ch in enumerate(ims):
        small = np.asarray(ch.resize((n, n), Image.BICUBIC)).astype(np.float64) / 32767.5 - 1
        res[o:o + n, o:o + n, c] = small
    return res
fg_small = shrink(np.concatenate([fg_res, alpha[..., None]], -1))
fg_res_s, alpha_s = fg_small[..., :3], fg_small[..., 3:4].clip(0, 1)

# 4) New background: full-bleed indigo -> deep navy gradient with a soft light behind the lens.
top = np.array([0.16, 0.20, 0.47]); bottom = np.array([0.02, 0.03, 0.10])
t = (yy ** 0.9)[..., None]
bg = top * (1 - t) + bottom * t
glow = np.exp(-((xx - 0.5) ** 2 + (yy - 0.46) ** 2) / (2 * 0.22 ** 2))[..., None]
bg = bg + glow * np.array([0.10, 0.10, 0.26]) * 0.9
# old background colour under the artwork, for the residual transfer
bg_old_c = np.array([0.05, 0.08, 0.17])
comp = bg + fg_res_s + (bg_old_c - bg) * alpha_s * 0.0
img = Image.fromarray((comp.clip(0, 1) * 255 + 0.5).astype(np.uint8))
img.save(out_path)
