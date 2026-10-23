# Shadow cutout seam experiment

The Hyprland shadow shader removes shadow inside a binary rounded-rectangle
cutout. The captured Mac surface has translucent edge pixels there. Inset the
cutout by one render pixel and reduce its radius by one pixel to retain shadow
under the antialiased edge. No source pixels or window geometry are changed.

Live A/B capture of the same visible proxy corner at (1570,1235), 140x150
logical pixels, showed 39 pixels with changes above 5/255 in the corner's
70x70 region; maximum channel change was 43/255. For example (61,47) changed
from [232,242,242] to [192,204,204]. Screenshots were passive, without input
or focus changes. Runtime shader compilation returned ok; configerrors empty.

This is a session-only global shadow shader experiment, not a permanent
Viewflow-specific patch. It also affects other shadows using the same shader.
It does not fix the independently identified overview cutout-transform mismatch.

Apply: hyprctl reloadshaders /home/wilf/data/viewflow/docs/evidence/mac-shadow-seam-20260912
Restore default shaders: hyprctl reloadshaders
