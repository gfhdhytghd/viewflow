# Independent band textures and complete-frame publication

Added banded_staging.hpp prototype, not yet used by production capture. Three-slot leased pool,1..16independent staging textures per capture,one completionquery per band,one flush after queued copies. Each band texture can Map after its own completion without mapping the later bands' resources. BandPublication polls nonblocking,appends completed bands to owned SHMslot,and returns a reference only after finish. Pool exhaustion returns no new snapshot. Destruction releases transaction/frame leases. Context operations require existing caller serialization.

BandedStaging::assemble copies all bands to a BGRAatlas with explicit destination bounds; this supplies a coherent multiwindow fallback mechanism without adding a duplicate full staging copy to every capture.

Extended actual D3D test with1/4/16requested bands,whole17x13 and cropped7x5,full pixel comparisons for SHMpublication andGPUatlasreconstruction,threeleasedslots/exhaustion/recovery. Existing capture/readback tests retained. Pending runtime integration: source snapshot representation, direct selection/adoption,atlas-copy sites,supersession anddiagnosticmarkers. No claim of hardware overlap or performance improvement until6Khardware timing verifies it. No live deployment or desktop input. Goal unmet.

Validation completed: Windows Release build, WARP17x13 suite, and actual hardware6144x3456 suite all exit0. Both full banded pixel publication andGPUatlas reconstruction passed at6K. This proves correctness in an isolated GPU test,not overlap efficiency or live fusion behavior.
