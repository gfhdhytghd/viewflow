# Per-frame upload attribution

GpuDecoder::begin_progressive accepts optional diagnostic PTS; live caller supplies frame.pts. Progressive texture trace now includes exact signed64bit PTS. Separate progressive-release trace measures CPU cleanup after publication, including completion notification drain. No wire protocol, frame ownership or scheduling change; diagnostics remain gated. Legacy calls default to0 and must not be treated as real live frame identities.

Analyzer preserves PTS as integers rather than floats, counts identity-bearing records, and joins cleanup durations where available. Legacy logs retain timing summaries without inventing identities. Durations are CPU wall time and cannot be called GPU execution time.

Linux native and hardware texture test builds passed. GPU test sends explicitPTS424242 and verifies matching texture/release trace entries alongside all84934656bytes,mismatches0,completion notification,abort snapshot,bank reuse,shared registration,warm generations and shrink/grow checks. Test output progressive-identity-test.log. This closes diagnostic test validation only; no new live transport run or production deployment this turn. Next live trial can correlate upload/cleanup with exact presentation frames instead of comparing unrelated percentiles.
