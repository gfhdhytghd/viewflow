//! Deterministic platform backend used to exercise the platform-independent
//! capture/admission/presentation boundary. It is not a native backend.

use std::collections::BTreeMap;

use viewflow_protocol::{
    DeviceTopology, FramePlane, FramePlaneReady, GeometryEpoch, Rect, WindowDescriptor,
    WindowFamilyId, WindowId,
};

use crate::{
    AlphaMode, BlurMode, CapturedFrame, FrameCapabilities, PlatformBackend, PlatformError,
    PlatformKind, ProxyLifecycle, SharedTexture, TextureFormat,
};

#[derive(Debug)]
pub struct FakeBackend {
    topology: DeviceTopology,
    windows: Vec<WindowDescriptor>,
    capabilities: FrameCapabilities,
    protected: bool,
    proxies: BTreeMap<WindowId, ProxyLifecycle>,
    captured: Vec<CapturedFrame>,
}

impl FakeBackend {
    #[must_use]
    pub fn new(topology: DeviceTopology, windows: Vec<WindowDescriptor>) -> Self {
        Self {
            topology,
            windows,
            capabilities: FrameCapabilities {
                capture: true,
                presentation: true,
                separate_alpha: true,
                exact_blur: false,
                rejects_protected_content: true,
            },
            protected: false,
            proxies: BTreeMap::new(),
            captured: Vec::new(),
        }
    }

    #[must_use]
    pub fn capabilities(&self) -> FrameCapabilities {
        self.capabilities
    }

    pub fn set_protected_content(&mut self, protected: bool) {
        self.protected = protected;
    }

    #[must_use]
    pub fn proxy(&self, window: WindowId) -> ProxyLifecycle {
        self.proxies
            .get(&window)
            .copied()
            .unwrap_or(ProxyLifecycle::Absent)
    }

    #[must_use]
    pub fn captured(&self) -> &[CapturedFrame] {
        &self.captured
    }
}

impl PlatformBackend for FakeBackend {
    fn kind(&self) -> PlatformKind {
        PlatformKind::Hyprland
    }

    fn topology(&self) -> Result<DeviceTopology, PlatformError> {
        Ok(self.topology.clone())
    }

    fn enumerate_windows(&self) -> Result<Vec<WindowDescriptor>, PlatformError> {
        Ok(self.windows.clone())
    }

    fn virtualize_family(
        &mut self,
        family: WindowFamilyId,
        _render_scale: f64,
    ) -> Result<(), PlatformError> {
        if self.windows.iter().any(|window| window.family_id == family) {
            Ok(())
        } else {
            Err(PlatformError::BackendFailure)
        }
    }

    fn create_proxy(
        &mut self,
        window: WindowId,
        _visible_bounds_dip: Rect,
    ) -> Result<(), PlatformError> {
        if self.windows.iter().any(|candidate| candidate.id == window) {
            self.proxies.insert(window, ProxyLifecycle::Created);
            Ok(())
        } else {
            Err(PlatformError::BackendFailure)
        }
    }

    fn apply_geometry(&mut self, geometry: GeometryEpoch) -> Result<(), PlatformError> {
        let Some(proxy) = self.proxies.get_mut(&geometry.window_id) else {
            return Err(PlatformError::BackendFailure);
        };
        if geometry.phase == viewflow_protocol::GeometryPhase::End {
            *proxy = ProxyLifecycle::Created;
        } else {
            *proxy = ProxyLifecycle::GeometryPending(geometry.epoch);
        }
        Ok(())
    }

    fn capture_plane(&mut self, ready: FramePlaneReady) -> Result<SharedTexture, PlatformError> {
        if self.protected && self.capabilities.rejects_protected_content {
            return Err(PlatformError::ProtectedContent);
        }
        let alpha = if ready.plane == FramePlane::Alpha {
            AlphaMode::SeparatePlane
        } else {
            AlphaMode::Premultiplied
        };
        self.captured.push(CapturedFrame {
            window_id: ready.window_id,
            frame_id: ready.frame_id,
            geometry_epoch: ready.geometry_epoch,
            plane: ready.plane,
            alpha,
            blur: BlurMode::None,
            protected_content: self.protected,
        });
        Ok(SharedTexture {
            id: viewflow_protocol::Id128(u128::from(ready.frame_id)),
            width: 1,
            height: 1,
            format: if ready.plane == FramePlane::Alpha {
                TextureFormat::Alpha8
            } else {
                TextureFormat::Bgra8Srgb
            },
        })
    }

    fn present_proxy(
        &mut self,
        window: WindowId,
        texture: SharedTexture,
    ) -> Result<(), PlatformError> {
        let Some(proxy) = self.proxies.get_mut(&window) else {
            return Err(PlatformError::BackendFailure);
        };
        let Ok(frame_id) = u64::try_from(texture.id.0) else {
            return Err(PlatformError::BackendFailure);
        };
        *proxy = ProxyLifecycle::Presented {
            frame_id,
            geometry_epoch: 0,
        };
        Ok(())
    }
}
