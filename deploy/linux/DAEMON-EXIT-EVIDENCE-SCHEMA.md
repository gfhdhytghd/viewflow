# Normal daemon-exit evidence schema

\`collect-viewflow-daemon-exit-evidence.sh\` consumes the untouched normal
protocol-2.1 schema-4 runtime receipt after \`viewflowd\` has exited itself. It
does not stop or start either service.

The producer creates two owner-only (\`0600\`) files without replacing an
existing path:

- The raw observation sidecar has \`schema_version: 1\` and
  \`state: "viewflow-daemon-exit-observation"\`. It binds the operation, runtime
  receipt SHA-256, daemon PID/start-ticks/boot/hash/instance, systemd
  InvocationID selected uniquely from the receipt PID/boot journal, the exact
  journal query, raw command outputs, raw journal JSON entries, and observation
  time. The unit's \`InvocationID\` property may be empty after exit; when it is
  still present it must match the journal-selected value. The recovered value
  is persisted as \`command_outputs.journal_selected_invocation_id\` and must
  match the evidence's top-level \`invocation_id\`.
- The consumer evidence has \`schema_version: 1\` and
  \`state: "viewflow-daemon-exited"\`. It preserves the flat compatibility fields
  \`daemon_pid\`, \`daemon_start_ticks\`, \`boot_id\`, \`unit\`, \`active_state\`,
  \`main_pid\`, \`exact_process_count\`, \`udp_listener_count\`,
  \`sidecar_socket_present\`, \`observation_sha256\`, and
  \`observed_at_unix_ms\`. It also carries the receipt hash, daemon instance/hash,
  InvocationID, protocol, exact journal query/count/timestamps/slice hash,
  structured exit status, and embedded raw command outputs.

\`observation_sha256\` is the SHA-256 of the exact raw sidecar bytes. A consumer
must receive both files, recompute that hash, and compare it to the main
evidence. It must also recompute the runtime receipt hash, match all operation
and daemon identity fields, enforce freshness, and recheck the stopped state.
