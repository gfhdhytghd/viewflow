# Source loop waits and poll timing

This isolated 69-file candidate instruments the five existing 1 ms sleeps and the CPU duration of encoder polling, inventory and alpha polling. Timing samples aggregate into 1 ms histogram bins; slow events are bounded and printed after streaming. It does not change sleep, scheduling or power policy. Six Windows CTests pass and local/remote source hashes match.

The 100-second observation reaches 59.917 FPS, with upper-envelope median/P95 67.444/83.722 ms. All 5812 observed steady markers pair uniquely. Requested 1 ms waits average about 1.8–1.9 ms and their largest sample is 3.444 ms: this run does not show a 15.6 ms sleep-quantization problem. Inventory reaches 72.129 ms and alpha polling 21.138 ms at their maxima; these remain diagnostic leads, without a claimed causal correction.

6950 outputs are an exact ordered prefix of 6952 accepted frames; the two remaining frames belong to the bounded stop. Two drain cycles complete without input interleaving. The source/receiver exit normally and private tasks, proxies and nested compositor are removed. C914 remains installed. The user quota stop condition was observed at 7% remaining; no further experiments or scheduling changes were started.
