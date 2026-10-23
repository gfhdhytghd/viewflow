#!/usr/bin/env python3
"""Export the approved Linux logo for every platform, without changing its artwork.

Requires tools/requirements-branding.txt. Generated files are checked in so
native application builds do not need Qt or Pillow to prepare their icons.
"""
import io
import os
from pathlib import Path
import shutil
os.environ['QT_QPA_PLATFORM'] = 'offscreen'
from PIL import Image
from PySide6.QtCore import QBuffer, QIODevice, QRectF, Qt
from PySide6.QtGui import QImage, QPainter
from PySide6.QtSvg import QSvgRenderer
from PySide6.QtWidgets import QApplication

ROOT = Path(__file__).resolve().parents[1]
BRAND = ROOT / 'platform/branding'


def main():
    app = QApplication.instance() or QApplication([])
    renderer = QSvgRenderer(str(BRAND / 'viewflow.svg'))
    if not renderer.isValid():
        raise ValueError('invalid canonical Viewflow SVG')
    images = {}
    for size in (16, 20, 24, 32, 40, 48, 64, 128, 256, 512, 1024):
        raster = QImage(size, size, QImage.Format.Format_ARGB32)
        raster.fill(Qt.GlobalColor.transparent)
        painter = QPainter(raster)
        renderer.render(painter, QRectF(0, 0, size, size))
        painter.end()
        buffer = QBuffer(); buffer.open(QIODevice.OpenModeFlag.WriteOnly)
        if not raster.save(buffer, 'PNG'):
            raise RuntimeError('could not render logo')
        images[size] = Image.open(io.BytesIO(bytes(buffer.data()))).convert('RGBA')
    images[1024].save(BRAND / 'viewflow.png')
    images[1024].save(BRAND / 'Viewflow.icns', append_images=list(images.values()))
    images[256].save(BRAND / 'viewflow.ico', sizes=[(n, n) for n in images if n <= 256],
                     append_images=[image for n, image in images.items() if n < 256])
    # Actual menu-bar sizes avoid blurry downsampling in AppKit.
    images[20].save(BRAND / 'viewflow-menu.png')
    images[40].save(BRAND / 'viewflow-menu@2x.png')
    shutil.copy2(BRAND / 'viewflow.svg', ROOT / 'platform/desktop-app/qml/viewflow.svg')
    shutil.copy2(BRAND / 'viewflow.svg', ROOT / 'landing/public/favicon.svg')
    shutil.copy2(BRAND / 'viewflow.svg', ROOT / 'landing/public/viewflow.svg')
    images[256].resize((180, 180), Image.Resampling.LANCZOS).save(ROOT / 'landing/public/apple-touch-icon.png')
    print('Generated ICO, ICNS, PNG, menu-bar and web assets from platform/branding/viewflow.svg')


if __name__ == '__main__':
    main()
