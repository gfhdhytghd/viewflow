use viewflow_core::{FrameAdmission, FrameQueue, FrameQueueConfig, WindowSession};
use viewflow_platform::{AlphaMode, FakeBackend, PlatformBackend, PlatformError, ProxyLifecycle};
use viewflow_protocol::{
    DeviceTopology, FramePlane, FramePlaneReady, GeometryEpoch, GeometryPhase, Id128, Point, Rect,
    Size, WindowDescriptor, WindowRole,
};

fn descriptor() -> WindowDescriptor {
    WindowDescriptor {
        id: Id128(7),
        family_id: Id128(8),
        source_device: Id128(9),
        role: WindowRole::Main,
        bounds_dip: Rect {
            origin: Point::default(),
            size: Size {
                width: 640.0,
                height: 480.0,
            },
        },
        min_size_dip: Size {
            width: 1.0,
            height: 1.0,
        },
        max_size_dip: None,
        has_alpha: true,
        blur_radius_dip: None,
    }
}

fn plane(frame_id: u64, plane: FramePlane, received_ns: u64) -> FramePlaneReady {
    FramePlaneReady {
        window_id: Id128(7),
        frame_id,
        geometry_epoch: 1,
        plane,
        source_submitted_ns: 1_000_000,
        received_ns,
    }
}

#[test]
fn fake_capture_atomic_admission_and_geometry_then_presentation() {
    let window = descriptor();
    let mut backend = FakeBackend::new(
        DeviceTopology {
            generation: 1,
            displays: vec![],
        },
        vec![window.clone()],
    );
    assert!(backend.capabilities().separate_alpha);
    backend.create_proxy(window.id, window.bounds_dip).unwrap();
    backend
        .apply_geometry(GeometryEpoch {
            window_id: window.id,
            epoch: 1,
            phase: GeometryPhase::End,
            bounds_dip: window.bounds_dip,
        })
        .unwrap();

    let mut session = WindowSession::new(window.clone());
    assert!(
        !session
            .apply_geometry(GeometryEpoch {
                window_id: Id128(7),
                epoch: 1,
                phase: GeometryPhase::Begin,
                bounds_dip: Rect {
                    origin: Point::default(),
                    size: Size {
                        width: 700.0,
                        height: 500.0
                    }
                }
            })
            .unwrap()
    );
    assert!(
        session
            .apply_geometry(GeometryEpoch {
                window_id: Id128(7),
                epoch: 1,
                phase: GeometryPhase::End,
                bounds_dip: Rect {
                    origin: Point::default(),
                    size: Size {
                        width: 700.0,
                        height: 500.0
                    }
                }
            })
            .unwrap()
    );

    let mut queue = FrameQueue::new(FrameQueueConfig {
        refresh_millihz: 60_000,
        max_refresh_periods: 2,
        requires_alpha: true,
    });
    queue.set_geometry_epoch(1);
    let color = plane(10, FramePlane::Color, 10_000_000);
    let alpha = plane(10, FramePlane::Alpha, 11_000_000);
    let color_texture = backend.capture_plane(color).unwrap();
    assert_eq!(queue.push(color), FrameAdmission::Waiting);
    let alpha_texture = backend.capture_plane(alpha).unwrap();
    assert!(
        matches!(queue.push(alpha), FrameAdmission::Ready(manifest) if manifest.frame_id == 10)
    );
    assert_eq!(backend.captured()[1].alpha, AlphaMode::SeparatePlane);
    backend.present_proxy(window.id, color_texture).unwrap();
    backend.present_proxy(window.id, alpha_texture).unwrap();
    assert!(matches!(
        backend.proxy(window.id),
        ProxyLifecycle::Presented { frame_id: 10, .. }
    ));

    backend.set_protected_content(true);
    assert_eq!(
        backend.capture_plane(plane(11, FramePlane::Color, 12_000_000)),
        Err(PlatformError::ProtectedContent)
    );
}
