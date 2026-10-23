# Opt-in full capture-to-publication band path

VIEWFLOW_SHM_CAPTURE_BANDS=4 together with existingCAPTURE_STAGING1 now selects four independent staging bands in actual capture callback. Source inventory and metadata recognize band snapshots with no whole texture. Single-full-resident-window direct selection adopts bands into bounded Readback. Partial residency andmultiwindowatlas use copy_region intersections across bands,includingnonzero crop origins anddifferentatlas destination origins. No extra whole staging allocation on direct path. Default remains whole-texture capture.

Added actualGPU region-reconstruction test: crops across band boundaries and relocates to atlas0,0,then checks every affected pixel against original;1/4/16bands,whole/cropped frame sizes. Windows nativeReleasebuild and WARP17x13/hardware6144x3456 capturetests passed. Logs label captured_bands separately; disabled misleading whole-texture capture-stage durations for band mode. No6Kperformanceclaim; notyetlive deployed. Bounded experiment runners prepared with same60Hzpixelmarker and5mscompositorcontrol,automaticproductionrestore.

Pending: liveband path activationreadback,throughput/endtoendpixelverifiedtiming,any actualoverlap measurement,multiwindowinteractiveacceptance(user-operated). Existing tests cover atlas mechanism but not all live window transitions. Goal unmet.
