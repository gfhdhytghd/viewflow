# Win-drag shared control queue failure

After the resize timer fix, the user held Win and dragged a Linux proxy on Windows. Windows logged `atlas shared control queue unavailable: no available capacity` during native handoff, closed the connection with `atlas handoff control ended`, and Linux then retired its sender. This is a separate failure from the timer ID collision.

`AtlasReceiverSession` now retains one pending bounded-channel send when the shared consumer is full. Reliable reads pause behind that record to preserve order. Current media datagrams, native completion, and fenced recovery futures can still progress. The pending send belongs to the session and survives a caller timeout, cancellation, or completed native handoff. Actual consumer closure and invalid/replayed protocol records still report errors.

Validation: all 32 atlas session tests and all 4 cursor receiver tests passed. Regression coverage includes a full one-slot queue, repeated wait after timeout, ordered authorizations before media, native completion while control forwarding is blocked, and cancellation/resumption of a fenced recovery wait. Windows Release compilation succeeded.

Only the Windows receiver executable was replaced with SHA-256 `BA3EEE935F79CCAB9B9790B40E075A6FAC6C21CACAE72CCAF81FBAC0D39F84FE`. The presenter retains the preceding timer fix. Runtime paths/hashes and advancing native frame logs are recorded in runtime.json. The existing Linux service was restarted after the Windows listener was ready; no input or focus was synthesized. Physical Win-drag acceptance remains pending.
