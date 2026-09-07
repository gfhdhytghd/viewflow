use std::io::{Cursor, Read};
use std::net::{Ipv4Addr, SocketAddr, SocketAddrV4};

use viewflow_platform::sidecar::{
    BoundPeerIdentity, CodecError, EdgeActivated, KeyInput, KeyboardHidInput, MAX_FRAME_BYTES,
    MAX_HID_REPORT_BYTES, MessageDirection, PointerButtonInput, PointerInput, PointerWheelInput,
    RawHidReport, RawHidReportBundle, RejectCode, RelativePointerInput, ReleaseAllInput,
    ReturnToLocal, SidecarEdge, SidecarInputLease, SidecarMessage, SidecarRequest, SidecarSession,
    read_request, write_request,
};
use viewflow_protocol::{Id128, InputLease, InputLeaseState, InputSwitchState, PointerButton};

struct FragmentedReader<R> {
    inner: R,
    maximum_read: usize,
}

impl<R: Read> Read for FragmentedReader<R> {
    fn read(&mut self, buffer: &mut [u8]) -> std::io::Result<usize> {
        let length = buffer.len().min(self.maximum_read);
        self.inner.read(&mut buffer[..length])
    }
}

fn bound_peer() -> BoundPeerIdentity {
    BoundPeerIdentity {
        epoch: 9,
        address: SocketAddr::V4(SocketAddrV4::new(Ipv4Addr::new(192, 0, 2, 7), 24800)),
    }
}

fn sidecar_lease(lease: InputLease) -> SidecarInputLease {
    SidecarInputLease {
        lease,
        bound_peer: bound_peer(),
    }
}

fn active_lease(generation: u64) -> SidecarInputLease {
    sidecar_lease(InputLease {
        generation,
        owner: Id128(1),
        route_to: Id128(2),
        state: InputLeaseState::Active,
    })
}

fn offered_lease(generation: u64) -> SidecarInputLease {
    let mut lease = active_lease(generation);
    lease.lease.state = InputLeaseState::Offered;
    lease
}

fn activate_lease(session: &mut SidecarSession, offered_generation: u64) -> u64 {
    let active_generation = offered_generation + 1;
    session
        .accept(SidecarRequest {
            sequence: offered_generation,
            message: SidecarMessage::InputLease(offered_lease(offered_generation)),
        })
        .unwrap();
    session
        .accept(SidecarRequest {
            sequence: active_generation,
            message: SidecarMessage::InputLease(active_lease(active_generation)),
        })
        .unwrap();
    active_generation
}

#[test]
#[allow(clippy::too_many_lines)]
fn fragmented_reads_round_trip_all_input_shapes() {
    let requests = vec![
        SidecarRequest {
            sequence: 1,
            message: SidecarMessage::InputLease(active_lease(7)),
        },
        SidecarRequest {
            sequence: 2,
            message: SidecarMessage::Pointer(PointerInput {
                generation: 7,
                target: Id128(10),
                x_dip: -12.5,
                y_dip: 99.25,
            }),
        },
        SidecarRequest {
            sequence: 3,
            message: SidecarMessage::Key(KeyInput {
                generation: 7,
                target: Id128(10),
                hid_usage: 0x07_0004,
                pressed: true,
            }),
        },
        SidecarRequest {
            sequence: 4,
            message: SidecarMessage::RawHidReportBundle(RawHidReportBundle {
                generation: 7,
                device_id: Id128(0x05ac_0324),
                interface: 2,
                reports: vec![
                    RawHidReport {
                        timestamp_ns: 100,
                        bytes: vec![1, 2, 3],
                    },
                    RawHidReport {
                        timestamp_ns: 110,
                        bytes: vec![4, 5],
                    },
                ],
            }),
        },
        SidecarRequest {
            sequence: 5,
            message: SidecarMessage::RelativePointer(RelativePointerInput {
                generation: 7,
                target_device: Id128(2),
                event_sequence: 1,
                apply_deadline_monotonic_ns: 1,
                delta_x_dip: 1.25,
                delta_y_dip: -2.5,
            }),
        },
        SidecarRequest {
            sequence: 6,
            message: SidecarMessage::PointerButton(PointerButtonInput {
                generation: 7,
                target_device: Id128(2),
                event_sequence: 2,
                apply_deadline_monotonic_ns: 2,
                button: PointerButton::Back,
                state: InputSwitchState::Pressed,
            }),
        },
        SidecarRequest {
            sequence: 7,
            message: SidecarMessage::PointerWheel(PointerWheelInput {
                generation: 7,
                target_device: Id128(2),
                event_sequence: 3,
                apply_deadline_monotonic_ns: 3,
                vertical_delta_detents: 0.25,
                horizontal_delta_detents: -1.0,
            }),
        },
        SidecarRequest {
            sequence: 8,
            message: SidecarMessage::KeyboardHid(KeyboardHidInput {
                generation: 7,
                target_device: Id128(2),
                event_sequence: 4,
                apply_deadline_monotonic_ns: 4,
                usage_page: 0x07,
                usage_id: 0x04,
                state: InputSwitchState::Released,
                repeat: false,
            }),
        },
        SidecarRequest {
            sequence: 9,
            message: SidecarMessage::ReleaseAll(ReleaseAllInput {
                generation: 7,
                target_device: Id128(2),
                event_sequence: 5,
            }),
        },
        SidecarRequest {
            sequence: 10,
            message: SidecarMessage::EdgeActivated(EdgeActivated {
                route_generation: 12,
                source_display: Id128(20),
                route_to: Id128(2),
                edge: SidecarEdge::Right,
                edge_position: 0.625,
            }),
        },
        SidecarRequest {
            sequence: 11,
            message: SidecarMessage::ReturnToLocal(ReturnToLocal {
                generation: 7,
                target_display: Id128(20),
                edge: SidecarEdge::Right,
                edge_position: 0.625,
            }),
        },
    ];

    let mut encoded = Vec::new();
    for request in &requests {
        write_request(&mut encoded, request).unwrap();
    }
    let mut fragmented = FragmentedReader {
        inner: Cursor::new(encoded),
        maximum_read: 1,
    };
    for expected in requests {
        assert_eq!(read_request(&mut fragmented).unwrap(), Some(expected));
    }
    assert_eq!(read_request(&mut fragmented).unwrap(), None);
}

#[test]
fn oversized_frame_is_rejected_before_allocation() {
    let declared = u32::try_from(MAX_FRAME_BYTES + 1).unwrap();
    let mut bytes = Cursor::new(declared.to_be_bytes());
    assert!(matches!(
        read_request(&mut bytes),
        Err(CodecError::FrameTooLarge {
            declared: value,
            maximum: MAX_FRAME_BYTES,
        }) if value == MAX_FRAME_BYTES + 1
    ));
}

#[test]
fn oversized_hid_report_is_rejected_on_encode() {
    let request = SidecarRequest {
        sequence: 1,
        message: SidecarMessage::RawHidReportBundle(RawHidReportBundle {
            generation: 1,
            device_id: Id128(1),
            interface: 0,
            reports: vec![RawHidReport {
                timestamp_ns: 1,
                bytes: vec![0; MAX_HID_REPORT_BYTES + 1],
            }],
        }),
    };
    assert!(matches!(
        write_request(&mut Vec::new(), &request),
        Err(CodecError::ReportTooLarge {
            declared: value,
            maximum: MAX_HID_REPORT_BYTES,
        }) if value == MAX_HID_REPORT_BYTES + 1
    ));
}

#[test]
fn stale_generation_never_reaches_dispatch() {
    let mut session = SidecarSession::default();
    assert_eq!(activate_lease(&mut session, 7), 8);

    let stale = SidecarRequest {
        sequence: 2,
        message: SidecarMessage::Key(KeyInput {
            generation: 7,
            target: Id128(3),
            hid_usage: 4,
            pressed: true,
        }),
    };
    assert_eq!(session.accept(stale), Err(RejectCode::StaleGeneration));

    let future = SidecarRequest {
        sequence: 3,
        message: SidecarMessage::Pointer(PointerInput {
            generation: 9,
            target: Id128(3),
            x_dip: 0.0,
            y_dip: 0.0,
        }),
    };
    assert_eq!(session.accept(future), Err(RejectCode::FutureGeneration));
}

#[test]
fn wrong_target_is_rejected_without_consuming_event_sequence() {
    let mut session = SidecarSession::default();
    assert_eq!(activate_lease(&mut session, 7), 8);

    let motion = |request_sequence, target_device, event_sequence| SidecarRequest {
        sequence: request_sequence,
        message: SidecarMessage::RelativePointer(RelativePointerInput {
            generation: 8,
            target_device,
            event_sequence,
            apply_deadline_monotonic_ns: 1,
            delta_x_dip: 1.0,
            delta_y_dip: -1.0,
        }),
    };
    session.accept(motion(2, Id128(2), 1)).unwrap();
    assert_eq!(
        session.accept(motion(3, Id128(3), 2)),
        Err(RejectCode::WrongTarget)
    );
    session.accept(motion(4, Id128(2), 2)).unwrap();
}

#[test]
fn lease_transitions_event_sequence_and_disconnect_release_are_strict() {
    let mut session = SidecarSession::default();
    assert_eq!(activate_lease(&mut session, 10), 11);

    let motion = |request_sequence, generation, event_sequence| SidecarRequest {
        sequence: request_sequence,
        message: SidecarMessage::RelativePointer(RelativePointerInput {
            generation,
            target_device: Id128(2),
            event_sequence,
            apply_deadline_monotonic_ns: 1,
            delta_x_dip: 1.0,
            delta_y_dip: -1.0,
        }),
    };
    session.accept(motion(2, 11, 1)).unwrap();
    assert_eq!(
        session.accept(motion(3, 11, 1)),
        Err(RejectCode::ReplayedEvent)
    );

    session
        .accept(SidecarRequest {
            sequence: 4,
            message: SidecarMessage::InputLease(sidecar_lease(InputLease {
                generation: 12,
                state: InputLeaseState::Revoked,
                ..active_lease(11).lease
            })),
        })
        .unwrap();
    session
        .accept(SidecarRequest {
            sequence: 5,
            message: SidecarMessage::ReleaseAll(ReleaseAllInput {
                generation: 12,
                target_device: Id128(2),
                event_sequence: 2,
            }),
        })
        .unwrap();
    assert_eq!(
        session.accept(motion(6, 12, 3)),
        Err(RejectCode::LeaseNotActive)
    );
    assert_eq!(
        session.accept(SidecarRequest {
            sequence: 7,
            message: SidecarMessage::InputLease(active_lease(13)),
        }),
        Err(RejectCode::InvalidLeaseTransition)
    );
}

#[test]
fn lease_identity_and_transition_validation_is_strict() {
    let invalid_first_leases = [
        active_lease(1),
        sidecar_lease(InputLease {
            generation: 0,
            ..offered_lease(1).lease
        }),
        sidecar_lease(InputLease {
            owner: Id128(0),
            ..offered_lease(1).lease
        }),
        sidecar_lease(InputLease {
            route_to: Id128(0),
            ..offered_lease(1).lease
        }),
        sidecar_lease(InputLease {
            route_to: Id128(1),
            ..offered_lease(1).lease
        }),
    ];
    for lease in invalid_first_leases {
        assert_eq!(
            SidecarSession::default().accept(SidecarRequest {
                sequence: 1,
                message: SidecarMessage::InputLease(lease),
            }),
            Err(RejectCode::InvalidLeaseTransition)
        );
    }

    let mut session = SidecarSession::default();
    session
        .accept(SidecarRequest {
            sequence: 1,
            message: SidecarMessage::InputLease(offered_lease(1)),
        })
        .unwrap();
    assert_eq!(
        session.accept(SidecarRequest {
            sequence: 2,
            message: SidecarMessage::InputLease(active_lease(1)),
        }),
        Err(RejectCode::StaleGeneration)
    );
    assert_eq!(
        session.accept(SidecarRequest {
            sequence: 3,
            message: SidecarMessage::InputLease(sidecar_lease(InputLease {
                generation: 2,
                owner: Id128(3),
                route_to: Id128(4),
                state: InputLeaseState::Active,
            })),
        }),
        Err(RejectCode::InvalidLeaseTransition)
    );
    session
        .accept(SidecarRequest {
            sequence: 4,
            message: SidecarMessage::InputLease(sidecar_lease(InputLease {
                generation: 2,
                state: InputLeaseState::Revoked,
                ..active_lease(2).lease
            })),
        })
        .unwrap();
    session
        .accept(SidecarRequest {
            sequence: 5,
            message: SidecarMessage::InputLease(sidecar_lease(InputLease {
                generation: 3,
                owner: Id128(3),
                route_to: Id128(4),
                state: InputLeaseState::Offered,
            })),
        })
        .unwrap();
    session
        .accept(SidecarRequest {
            sequence: 6,
            message: SidecarMessage::InputLease(sidecar_lease(InputLease {
                generation: 4,
                owner: Id128(3),
                route_to: Id128(4),
                state: InputLeaseState::Active,
            })),
        })
        .unwrap();
}

#[test]
fn message_origin_is_explicitly_enforced() {
    let mut session = SidecarSession::default();
    let lease = SidecarRequest {
        sequence: 1,
        message: SidecarMessage::InputLease(offered_lease(3)),
    };
    assert_eq!(
        session.accept_from(MessageDirection::SidecarToDaemon, lease.clone()),
        Err(RejectCode::WrongDirection)
    );
    session
        .accept_from(MessageDirection::DaemonToSidecar, lease)
        .unwrap();

    let edge = SidecarRequest {
        sequence: 2,
        message: SidecarMessage::EdgeActivated(EdgeActivated {
            route_generation: 4,
            source_display: Id128(20),
            route_to: Id128(2),
            edge: SidecarEdge::Right,
            edge_position: 0.5,
        }),
    };
    assert_eq!(
        session.accept_from(MessageDirection::DaemonToSidecar, edge.clone()),
        Err(RejectCode::WrongDirection)
    );
    session
        .accept_from(MessageDirection::SidecarToDaemon, edge)
        .unwrap();
}

#[test]
fn codec_rejects_invalid_normalized_edges_and_input_values() {
    let invalid_edge = SidecarRequest {
        sequence: 1,
        message: SidecarMessage::EdgeActivated(EdgeActivated {
            route_generation: 1,
            source_display: Id128(20),
            route_to: Id128(2),
            edge: SidecarEdge::Right,
            edge_position: 1.01,
        }),
    };
    assert!(matches!(
        write_request(&mut Vec::new(), &invalid_edge),
        Err(CodecError::InvalidPayload(_))
    ));

    let invalid_motion = SidecarRequest {
        sequence: 2,
        message: SidecarMessage::RelativePointer(RelativePointerInput {
            generation: 1,
            target_device: Id128(2),
            event_sequence: 1,
            apply_deadline_monotonic_ns: 1,
            delta_x_dip: f64::NAN,
            delta_y_dip: 0.0,
        }),
    };
    assert!(matches!(
        write_request(&mut Vec::new(), &invalid_motion),
        Err(CodecError::NonFiniteCoordinate)
    ));

    let invalid_keyboard = SidecarRequest {
        sequence: 3,
        message: SidecarMessage::KeyboardHid(KeyboardHidInput {
            generation: 1,
            target_device: Id128(2),
            event_sequence: 1,
            apply_deadline_monotonic_ns: 1,
            usage_page: 0,
            usage_id: 4,
            state: InputSwitchState::Pressed,
            repeat: false,
        }),
    };
    assert!(matches!(
        write_request(&mut Vec::new(), &invalid_keyboard),
        Err(CodecError::InvalidPayload(_))
    ));

    let missing_deadline = SidecarRequest {
        sequence: 4,
        message: SidecarMessage::RelativePointer(RelativePointerInput {
            generation: 1,
            target_device: Id128(2),
            event_sequence: 1,
            apply_deadline_monotonic_ns: 0,
            delta_x_dip: 1.0,
            delta_y_dip: 0.0,
        }),
    };
    assert!(matches!(
        write_request(&mut Vec::new(), &missing_deadline),
        Err(CodecError::InvalidPayload(_))
    ));
}

#[cfg(unix)]
#[test]
#[allow(clippy::too_many_lines)]
fn unix_service_uses_owner_only_socket_and_acknowledges_sequence() {
    use std::fs;
    use std::os::unix::fs::PermissionsExt;
    use std::os::unix::net::UnixStream;
    use std::thread;

    use viewflow_platform::sidecar::{
        LocalSidecarListener, ServiceOutcome, SidecarResponse, read_response, serve_one,
    };

    let path = std::env::temp_dir().join(format!(
        "viewflow-sidecar-{}-{}.sock",
        std::process::id(),
        std::thread::current().name().unwrap_or("test")
    ));
    let _ = fs::remove_file(&path);
    let listener = LocalSidecarListener::bind(&path).unwrap();
    assert_eq!(
        fs::metadata(listener.path()).unwrap().permissions().mode() & 0o777,
        0o600
    );

    let server = thread::spawn(move || {
        let mut stream = listener.accept().unwrap();
        let mut session = SidecarSession::default();
        let rejected_lease = serve_one(&mut stream, &mut session, |_| {
            Err(RejectCode::BackendFailure)
        })
        .unwrap();
        assert_eq!(session.lease(), None);
        let accepted_offer = serve_one(&mut stream, &mut session, |_| Ok(())).unwrap();
        let accepted_active = serve_one(&mut stream, &mut session, |_| Ok(())).unwrap();
        let rejected_motion = serve_one(&mut stream, &mut session, |_| {
            Err(RejectCode::BackendFailure)
        })
        .unwrap();
        let accepted_motion = serve_one(&mut stream, &mut session, |_| Ok(())).unwrap();
        (
            rejected_lease,
            accepted_offer,
            accepted_active,
            rejected_motion,
            accepted_motion,
        )
    });
    let mut client = UnixStream::connect(&path).unwrap();
    let lease_request = SidecarRequest {
        sequence: 41,
        message: SidecarMessage::InputLease(offered_lease(1)),
    };
    write_request(&mut client, &lease_request).unwrap();
    assert_eq!(
        read_response(&mut client).unwrap(),
        Some(SidecarResponse {
            sequence: 41,
            result: Err(RejectCode::BackendFailure),
        })
    );
    write_request(
        &mut client,
        &SidecarRequest {
            sequence: 42,
            message: SidecarMessage::InputLease(offered_lease(1)),
        },
    )
    .unwrap();
    assert_eq!(
        read_response(&mut client).unwrap(),
        Some(SidecarResponse {
            sequence: 42,
            result: Ok(()),
        })
    );
    write_request(
        &mut client,
        &SidecarRequest {
            sequence: 43,
            message: SidecarMessage::InputLease(active_lease(2)),
        },
    )
    .unwrap();
    assert_eq!(
        read_response(&mut client).unwrap(),
        Some(SidecarResponse {
            sequence: 43,
            result: Ok(()),
        })
    );
    let motion = RelativePointerInput {
        generation: 2,
        target_device: Id128(2),
        event_sequence: 1,
        apply_deadline_monotonic_ns: 1,
        delta_x_dip: 3.0,
        delta_y_dip: -4.0,
    };
    write_request(
        &mut client,
        &SidecarRequest {
            sequence: 44,
            message: SidecarMessage::RelativePointer(motion),
        },
    )
    .unwrap();
    assert_eq!(
        read_response(&mut client).unwrap(),
        Some(SidecarResponse {
            sequence: 44,
            result: Err(RejectCode::BackendFailure),
        })
    );
    write_request(
        &mut client,
        &SidecarRequest {
            sequence: 45,
            message: SidecarMessage::RelativePointer(motion),
        },
    )
    .unwrap();
    assert_eq!(
        read_response(&mut client).unwrap(),
        Some(SidecarResponse {
            sequence: 45,
            result: Ok(()),
        })
    );
    let (rejected_lease, accepted_offer, accepted_active, rejected_motion, accepted_motion) =
        server.join().unwrap();
    assert_eq!(
        rejected_lease,
        ServiceOutcome::Rejected(RejectCode::BackendFailure)
    );
    assert!(matches!(
        accepted_offer,
        ServiceOutcome::Accepted(event)
            if matches!(*event, SidecarMessage::InputLease(_))
    ));
    assert!(matches!(
        accepted_active,
        ServiceOutcome::Accepted(event)
            if matches!(*event, SidecarMessage::InputLease(_))
    ));
    assert_eq!(
        rejected_motion,
        ServiceOutcome::Rejected(RejectCode::BackendFailure)
    );
    assert_eq!(
        accepted_motion,
        ServiceOutcome::Accepted(Box::new(SidecarMessage::RelativePointer(motion)))
    );
    assert!(!path.exists());
}
