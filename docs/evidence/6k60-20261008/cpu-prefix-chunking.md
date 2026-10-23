# CPU publication chunking candidate

User explicitly chose to preserve active Fréchet research tasks and continue code optimization. No further live performance benchmark or signal to those jobs.

Added default-off VIEWFLOW_SHM_PUBLICATION_ROWS=1024 to Windows BandPublication. After a GPU staging band is ready/mapped, split its CPU→IVSHMEM append into <=1024row immutable prefixes while retaining mapped texture and writer ownership. Two GPU staging bands/queries/Flush operations remain unchanged; receiver already consumes monotonically growing prefixes. In6144x3456two-band case each1728row band splits1024+704 rows; both pieces exceed existing16MiBparallel-copy threshold. SHM1 unchanged. Exceptions retain existing unmap and writer-abort path; full frame completion still requires all rows. Potential tradeoff:more CPU worker dispatches,atomic publications,hostDMA submissions.

Windows Release reverse build result tracked in current tool output. Correctness and performance of the new opt-in path still need dedicated GPU/live validation when resources permit. Existing default remains one CPU publication per GPU band. No production deployment or speedup claim. Timeline currently reports whole-band copy/publish observations, not every new subchunk; host row-range submissions may coalesce chunks and must be interpreted accordingly.

## CPU correctness coverage

Moved chunk splitting into shared Write::append_chunked used by Windows production candidate. Full-span prevalidation occurs before any prefix publication, including last-row/pitch/remaining-height bounds. Tests cover padded rows,chunk0/1/3/1024,short tail,invalid truncated source with empty prefix retained,and earlier prefix unchanged by later append. Existing6K concurrent full-byte test now uses two1728row source bands split1024+704,checking all84934656bytes while reader observes published prefixes. Linux g++ CPU test passed(cpu-prefix-chunk-test.log),no GPU workload. Windows candidate/native test rebuilt with assertions enabled; result tracked in tool output. These tests validate shared chunk storage, not D3DMap integration or actual DMA performance. Opt-in remains off,normalservices unchanged,researchjobs preserved.

## Streaming/parallel visibility coverage

Expanded concurrent6K chunk test to3modes:cached memcpy,streaming single-thread,streaming parallel2threads with AVX2 requested and normal capability fallback. Each mode splits1728row GPU-like source bands into1024+704row append chunks and concurrently validates all84934656published bytes. Linux and Windows CPU tests passed all3modes with assertions enabled. This exercises production copy/fence/publication code without GPU or actual IVSHMEM mappings; hardware DMA/guest-host mapping integration remains unverified for the new option. No timing or throughput claim; research jobs untouched.

## Host RAM scheduling-cost screen

`cpu-publication-bench.cpp` is a bounded CPU-only comparison using the production
storage/copy path, two persistent AVX2-capable copy threads, 6144x3456 BGRA,
and two 1728-row source bands. It alternates AB/BA order, excludes four warmup
pairs, collects 24 samples per arm, and prints only after measurement. Buffer
allocation/initialization and final byte validation are outside timing.

In `cpu-publication-host.csv`, whole-band publication median frame CPU wall time
was 4.050959 ms; 1024-row publication was 4.094260 ms (about 0.043 ms higher).
Maxima were 5.048239 and 5.005800 ms respectively. This small, single host-RAM
sample does not establish a statistically reliable difference. Research jobs
were preserved; their contention was not controlled. There is no guest staging
mapping, actual IVSHMEM, concurrent GPU consumer, or presentation in this test.
The first-band metric is completion of the entire 1728-row band, not latency of
the first 1024-row prefix.

Decision: no evidence here justifies adding a more complex persistent chunk
scheduler. Keep the simple default-off candidate for later guest/IVSHMEM/GPU
validation; neither deploy it nor infer end-to-end speedup from this result.
