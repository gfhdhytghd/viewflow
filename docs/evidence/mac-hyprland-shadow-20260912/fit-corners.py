from pathlib import Path
import numpy as np
from PIL import Image
from scipy.optimize import least_squares

root = Path(__file__).parent
image = np.asarray(Image.open(root/'native-reference.png').convert('RGB'))[:, :, 0]
y, x = np.indices(image.shape)
outside = (x < 100) | (x >= 1309) | (y < 100) | (y >= 925)
corners = outside & ((x < 160) | (x > 1249)) & ((y < 160) | (y > 865))
px, py, target = x[corners]+.5, y[corners]+.5, image[corners]/255.
lobes = [(88,13,14,17.5,.233), (74,0,0,19,.107), (2,0,0,0,.32)]

def predict(radii):
    transmission = np.ones_like(px)
    for (span, ix, iy, offset, opacity), radius in zip(lobes, radii):
        qx = np.abs(px-(100+1209/2)) - (1209/2-ix-radius)
        qy = np.abs(py-(100+825/2+offset)) - (825/2-iy-radius)
        sdf = np.hypot(np.maximum(qx,0),np.maximum(qy,0)) + np.minimum(np.maximum(qx,qy),0) - radius
        transmission *= 1-opacity*np.clip(1-sdf/span,0,1)**4
    return transmission

fit = least_squares(lambda r: predict(r)-target, [3,16,16], bounds=([0]*3,[100]*3))
print('radii', fit.x.tolist(), 'corner-rmse-byte',np.sqrt(np.mean(fit.fun**2))*255)
print('initial-model-rmse-byte',np.sqrt(np.mean((predict([3,16,16])-target)**2))*255)
