# Viewflow brand assets

The source is `viewflow.svg`, byte-for-byte the logo in the Linux application
installed on 2026-09-25: blue rounded square with white overlapping windows.
Do not substitute the exploratory Sidecar/recall symbol for this brand mark.

Run `python tools/generate-brand-assets.py` from an environment containing
`tools/requirements-branding.txt` after changing the source. Commit the generated
assets together. Normal native builds consume these exports without rendering.

- Qt sidebar, application/window and tray: copied SVG in desktop-app/qml.
- Linux launcher: hicolor SVG and `Icon=org.viewflow.app`.
- Windows executable, Start menu, installer/uninstaller and Programs & Features:
  multi-resolution ICO; runtime windows/tray use the same SVG.
- macOS Finder, Dock, app switcher, About, permission drag tile and associated
  connection documents: ICNS declared in Info.plist.
- macOS sidebar: PNG; menu bar: the same color logo at 20 and 40 pixels.
- DMG application and mounted volume: canonical ICNS; no alternate drawn logo.
- Website header/footer, demonstration app identity and browser/touch icon:
  copied SVG and PNG.

Action icons and icons belonging to shared third-party application windows keep
their own meanings; they are not Viewflow brand marks.
