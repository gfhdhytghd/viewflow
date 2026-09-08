# Rejected foreground flattening experiment

These are test-only snapshots, not production inputs. In an isolated source
copy matching this evidence entry, replace the three corresponding files under
`platform/windows-composition-preview/` with these snapshots. Build the
`viewflow_sparse_bind_profile` Release target. `--pixels` runs the pixel checks;
no argument runs the paired cold/repack and existing reference benchmarks.
The paired test alternates container/flat order for 24 iterations and discards
the first four, retaining 20 samples per mode. It measures initial scene
construction and the subsequent first-patch deletion/repacking separately.

The flat mode puts the shared brush on a full-atlas sprite with a translated
InsetClip, removing its enclosing container. The backdrop sprite keeps its
original patch bounds. Clip offsets are defined relative to their visual by
[Microsoft's CompositionClip documentation](https://learn.microsoft.com/en-us/uwp/api/windows.ui.composition.compositionclip).

Fifteen pixel variants passed, but performance did not establish an overall
win. For 195 blurred patches, construction median improved 41.281 to 37.676 ms
while the immediate repack median regressed 1.850 to 3.725 ms. Its construction
P95 also increased 53.989 to 57.294 ms. For 256 blurred patches, construction
medians were 52.293/50.036 ms and repack medians 4.470/3.260 ms, but repack P95
increased 5.386 to 7.752 ms. Results vary with compositor batching/contention;
these data do not support adopting a general improvement.

Production was restored to the container-based, source-rectangle cache after
this experiment. No live executable was deployed. See the sibling logs
`sparse-flat-pixels.log` and `sparse-flat-paired-benchmark.log`.
