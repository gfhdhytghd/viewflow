# Explicit zero-cadence lifecycle test

Native 60F2AEC6 passes all seven owned-window lifecycle phases, 21 accepted/output/GPU-decoded frames with exact alpha, and three runtime mode changes (four/two/four/two). All 20 drains complete without input interleaving or missing timestamps. Every WGC session reports supported cadence zero. Three fixture/build inputs match remotely, foreground samples remain unchanged and all private task processes exit. Phase-marker timing limitations remain in runs/mode-combined/summary.json. No physical input or scanout acceptance is claimed.
