# GPU occupancy guard for performance experiments

The user requested on 2026-10-09 that tests stop when the GPU is saturated, while code work may continue and research jobs remain running.

`tools/run-dma-6k60.py` checks all host NVIDIA GPUs before any service mutation and approximately once per second during its polling loops. Any reported utilization at or above 95%, or unavailable utilization, aborts the experiment. The observation is recorded in `gpu-state.json`, `gpu-samples.jsonl`, and `aborted.json`. This guard applies only to experiments; it does not stop normal Viewflow streaming or unrelated GPU workloads. It observes host NVIDIA utilization, not the Windows guest Intel GPU.

For a running experiment, the host writes the run's `stop.request`. The guest checks this while waiting for its owned fixture process and stops that retained process handle only. It then follows the existing peer/native drain and normal-service recovery path. Unconfirmed cleanup is recorded separately; an aborted experiment is not a successful performance result. SSH and GPU query latency mean this is a polling response, not an instantaneous hardware interlock.

The sampler can be used independently:

```sh
python3 tools/dma_gpu_guard.py --state /tmp/viewflow-gpu.json
```

The optional one-shot idle notifier uses the locally installed `codex queue` command, not Herdr:

```sh
python3 tools/wake-on-gpu-idle.py --thread EXISTING_THREAD_UUID --state /tmp/viewflow-gpu-idle.json
```

It must first observe a busy GPU, then observe all GPUs below 50% three times at ten-second intervals. It queues one notice to the explicit existing thread and exits. A per-thread process lock prevents duplicate watchers. It neither starts a benchmark nor creates another agent; queue success is not proof that a model turn has executed. Unknown samples reset the idle streak. Queue timeouts are not retried because delivery may already have occurred. The watcher expires after eight hours by default and is not installed as a boot service.

Validation: CPU fake sampler tests and an actual-runner preflight test with every external command replaced prove that busy/unknown preflight issues no guest call or service mutation. The guest PowerShell script parses successfully. Actual busy-during-fixture termination remains untested on a live GPU workload; no such test was started while the host was saturated.
