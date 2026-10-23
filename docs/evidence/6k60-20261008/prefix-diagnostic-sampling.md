# Independent sampled prefix completion diagnostics

VIEWFLOW_PROGRESSIVE_PREFIX_TRACE now independently controls GPU prefix events:unset/other disables,1 records every eligible upload,16 samples one in16begin calls per decoder starting with first. Ordinary VIEWFLOW_PROGRESSIVE_UPLOAD_TRACE no longer adds GPU prefix events. Sample flag gates EventRecord even after an event object has been cached. Existing completion notification,ownership and synchronization unchanged.

Linux native/texture builds passed. Headless6Ktests:upload-trace-only emitted0prefix-complete records;prefix stride16 emitted1including explicitPTS424242. Both passed full84934656pixel comparison,completion notification,abort snapshot,bank reuse,shared registration,warm generations and shrinkgrow. Tests verify gating/first sample and correctness; they are not a live16frame cadence or performance benchmark. Artifacts prefix-independent-disabled-test.log and prefix-independent-sampled-test.log.

No new live deployment. Next baseline should run with prefix completion trace absent to separate previous44event overhead from system variability. Do not interpret diagnostic sampling itself as meeting the performance objective.
