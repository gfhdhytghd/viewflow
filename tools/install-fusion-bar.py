#!/usr/bin/env python3
"""Add the Windows Start button to the existing HyprV Quickshell launcher pill."""
from pathlib import Path
import shutil

path = Path.home()/'.config/HyprV/quickshell/shell.qml'
text = path.read_text()
marker = '// Viewflow Windows fusion button'
if marker not in text:
    anchor = '                        Item {\n                            implicitWidth: workspaceRow.implicitWidth + 8'
    if text.count(anchor) != 1:
        raise SystemExit('Cannot locate the launcher pill; leave the bar unchanged')
    block = '''                        // Viewflow Windows fusion button
                        TextModule {
                            id: viewflowWindowsButton
                            label: "󰖳"
                            textColor: root.launchColor
                            fontFamily: root.baseFont
                            fontPixelSize: 17
                            moduleHeight: 38
                            interactive: true
                            hoverable: true
                            paddingLeft: 7
                            paddingRight: 7
                            onLeftClicked: {
                                console.info("Viewflow Start button clicked");
                                const point = viewflowWindowsButton.mapToGlobal(0, viewflowWindowsButton.height);
                                root.runDetached([root.homeDir + "/.local/bin/viewflow-windows", "start", "--anchor", String(Math.round(point.x)), String(Math.round(point.y + 8))]);
                            }
                            onRightClicked: root.runDetached([root.homeDir + "/.local/bin/viewflow-windows", "menu"])
                        }

'''
    backup = path.with_name('shell.qml.before-viewflow-fusion')
    if not backup.exists():
        shutil.copy2(path, backup)
    path.write_text(text.replace(anchor, block+anchor))
