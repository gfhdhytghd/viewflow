# Explicit reverse-source capture cadence candidate

This 69-file candidate replaces the experiment-only environment switch with an optional minimum capture interval on WindowCapture::start. The reverse source requests zero; other callers retain their existing default. Unsupported systems keep default capture. It retains deferred drain start and four/two public admission bounds. Six Windows CTests pass. The native SHA-256 begins 60F2AEC6.

The candidate is not deployed. In 100-second desktop observations, four-frame mode reaches 58.680 FPS but upper-envelope latency median/P95 is 85.279/86.780 ms. Two-frame mode with marker diagnostics reaches 59.257 FPS and median/P95 60.496/77.762 ms. Thus the earlier two short 58–59 ms P95 results do not establish sustained target performance.

The four-frame long run admits an additional queued input for much of the run: median source submit-to-color time is 37.45 ms for pending=2 versus 21.60 ms for pending=1. The two-frame long diagnostic uniquely pairs all 5748 steady observed markers, with capture-copy median 24.435 ms and encoding median/P95 22.226/34.499 ms. The exact diagnostic readback overhead is reported. A 91.05 ms clock-envelope outlier inflates its upper P99/max; lower-envelope P95 is still 76.90 ms, so it remains above target regardless.

Fresh lifecycle tests pass 21 frames, seven phases, exact alpha and three live mode changes, with every capture reporting interval zero. Pixel conversion, codec parameters, alpha and metadata processing remain byte-identical to the prior qualified processing path after the narrowly identified cadence/drain changes are removed; the inherited 90-marker quality comparison and its limits are explicitly recorded in method/processing-equivalence.json.

All long runs retain ordered output and drain accounting, normal exits and restored configuration, with private compositors/proxies removed. The installed source remains C914. [Microsoft API definition](https://learn.microsoft.com/en-us/uwp/api/windows.graphics.capture.graphicscapturesession.minupdateinterval) and [lifecycle evidence](../lifecycle-mode-combined/README.md).
