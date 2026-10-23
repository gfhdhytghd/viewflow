Intel VPL API headers, vendored from https://github.com/intel/libvpl
Revision: 674d015bcb294bc39fa276e99a652ea045423e82
License: MIT, see ../VPL-LICENSE.

The optional Intel HEVC backend loads an existing System32/libvpl.dll dynamically; no VPL import library or SDK installation is required to build. Only the stable encoding, dispatcher and external allocator interfaces are used. The measured runtime exposes API 2.16; initialization falls back to Media Foundation if unavailable.
