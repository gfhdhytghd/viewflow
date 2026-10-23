# Last-band readiness at first CPU mapping

1532valid6Kbanded submissions/1532observations: last band already ready in ALL1532,zero eligibility forGPU/CPUoverlap whenfirstMapbegins. This explains why splitting textures alone did not yield observed overlap. Does not distinguish commandbatchcompletionbehavior fromlatepolling/lock/scheduler timing. No GPUdurationclaim.

1533host marker recordsallmatch source. Foreground changedonce duringrun; latency/fps is confounded and not promoted as controlledcomparison. Wholeexperimentoriginalplugininventoryrestored,host/guestbinaries/wrappers/probehashrestored,diagnostic runtimeoverride removed. Rawgeneration→feedback49.462/62.962msretained onlyasobservation,not anoptimizationresult.

Next explicit control VIEWFLOW_SHM_BAND_FLUSH=1 flushes aftereachbandcopy/query instead ofonceafterallbands. Default remainsoneflush. Hypothesis: smallercommandbatches may exposeearlycompletion;thisisnotestablishedfactandflushoverheadmayregress. No busywaiting,timeoutgate orpartialframepublicationintroduced. Nativebuild/hardwaretesttrackedinthisturn;livecontrolnotyetperformed. Goalunmet.

Native/testReleasebuild and actual6Khardware suitepassedwithper-bandflush enabled. Thoseunitreadbackadoptionchecks occurafteranearlierpublicationand therefore theirreadyflags are not a timing/overlapexperiment;donotusethem toconcludeper-bandflushcannothelp.
