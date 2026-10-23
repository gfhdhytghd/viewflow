# Preserved failing lifecycle experiment

2026-09-09. An owned, nonactivating layered-window fixture changes title, moves, adds another window, resizes, hides and destroys windows. With capture-changes, the initial probe fails on a closed handle published with fallback title Windows and zero geometry. The resized first window also remains at its old captured size. Raw failure logs and diagnostic metadata are retained. These failures led to the fixes tested in ../lifecycle-v2/README.md. Native and fixture exit normally; the GPU semantic probe failure must not be interpreted as a passing runtime qualification.

Source, methods and raw observations are retained beside this report. `sha256.json` covers all archived files except itself.
