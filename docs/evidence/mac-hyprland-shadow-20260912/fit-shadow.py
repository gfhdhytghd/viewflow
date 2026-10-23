"""Fit Hyprland's power-4 shadow lobes to the white-background reference.

Read-only image analysis. Run with: uv run --with numpy --with pillow --with scipy fit-shadow.py
"""
from pathlib import Path
import json
import numpy as np
from PIL import Image
from scipy.optimize import least_squares

image = np.asarray(Image.open(Path(__file__).with_name('native-reference.png')).convert('RGB'))
distance = np.arange(2, 71, dtype=float)
d = distance.astype(int)
# Average clear mid-edge strips to avoid page contents and rounded corners.
profiles = np.stack([
    (image[300:650, 100-d, 0].mean(axis=0) + image[300:650, 1308+d, 0].mean(axis=0)) / 2,
    image[100-d, 450:950, 0].mean(axis=1),
    image[924+d, 450:950, 0].mean(axis=1),
])
target = 1 - profiles / 255

def predict(parameters):
    transmission = np.ones_like(target)
    for r, ix, iy, offset, opacity in parameters.reshape(-1, 5):
        extents = np.array([r-ix, r-iy-offset, r-iy+offset])
        alpha = opacity * np.clip((extents[:, None]-distance) / r, 0, 1)**4
        transmission *= 1 - alpha
    return 1 - transmission

lower = [20, 0, 0, -30, 0] * 2
upper = [180, 110, 110, 40, 0.95] * 2
best = None
rng = np.random.default_rng(12)
for _ in range(12):
    initial = [90, 15, 20, 12, 0.25, 50, 5, 10, 15, 0.20]
    initial = np.clip(np.array(initial) * rng.uniform(.8, 1.2, 10), lower, upper)
    fit = least_squares(lambda p: (predict(p)-target).ravel(), initial, bounds=(lower, upper), max_nfev=1500)
    if best is None or np.linalg.norm(fit.fun) < np.linalg.norm(best.fun): best = fit
print(json.dumps({'lobes_range_insetx_insety_offset_opacity': best.x.reshape(-1, 5).tolist(),
    'rmse_byte': float(np.sqrt(np.mean(best.fun**2))*255)}, indent=2))
