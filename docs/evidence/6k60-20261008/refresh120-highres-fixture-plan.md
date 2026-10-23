# Proposed controlled high-refresh source retest

Current guest config SHA256 verified A0F5A3FB82344F3D0F90DF92D213A46EB3BC0690F0FD3E9DB5AD5A9416B978EF, identical saved original. Proposed XML adds only6144x3456@120 capability; retains both60Hz modes,global60Hz,IntelGPU,two monitors,DPI/layout unchanged. Local XML parsed successfully; not deployed.

Unlike earlier120Hz tests, fixture remains high-resolution paced60Hz,SHM2 two bands,hostcompletionnotify,asyncdiagnostics. Old test generated~70-97fps and increased load, so cannot answer this controlled question. Applying new capability requires driver reload or Windows restart; previous reload3010/50 means prefer planned reboot if current work is saved. Need current user confirmation of unsaved app state before reboot; old confirmation preceded subsequent usage. Read-only SSH MainWindowTitle cannot certify interactive document state.

After authorized restart: query interactive topology, resolve primary6K by dimensions/role rather than staleDISPLAYname,verify120Hz CDS_TEST then temporary refresh switch; record actual mode and generatorcadence; run bounded30s benchmark; finally restore primary60Hz and verify layout,DPI,normalendpoints. Keep original config backup and original60Hz defaults. Restore original XML afterward; another restart may be required to remove advertised120Hz capability,so disclose possible second reboot. Do not claim original driver capability restored from file hash alone.

No XML installation,display mutation or reboot yet. If reboot unavailable, continue alternate source/host optimizations; do not repeat failed hot reload.
