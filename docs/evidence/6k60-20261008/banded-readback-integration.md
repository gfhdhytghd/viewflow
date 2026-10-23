# Banded adoption in existing readback queue

Readback::adopt_bands now reserves an owned SHMwrite transaction and stores BandPublication in existing bounded pending slots. poll preserves timestamp queue order,nonblocking completion checks andfull-frame-only reference publication. Frame andpublication leases are reset before consumer callback. Whole-texture supersession skips banded candidates rather than dereferencing absent completionqueries;bandedframescurrently drain in order without latest-ready optimization. Ordinary adopt/enqueue unchanged.

BandPublication records summed map/copy CPUwall durations and optional first-band pixel marker. ready_ms andgpu_copy_ms report-1 in this path because no whole-texture ready/GPUinterval exists; analysis must treat these as unavailable rather than negative elapsed time. Hardware overlap still unmeasured.

Extended tests adopt each1/4/16band whole/croppedframe via Readback,read exact pixels,andassert capturelease count restored before delivery;existing pool,atlas,whole-texture tests retained. Windows native/test Releasebuilds passed;WARP17x13 andhardware6144x3456 suites exit0. Not deployed; capture callback still generates whole textures in production. Next integrate band snapshot representation into source inventory/directselection/atlas composition with opt-in flag,then test multiwindow fallback andbounded live6Ktiming. Goal unmet.
