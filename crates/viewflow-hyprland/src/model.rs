use serde::Deserialize;
use viewflow_protocol::{DeviceId, Point, Rect, Size, WindowDescriptor, WindowRole};

use crate::{HyprWindowRecord, ids};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum AlphaCapability {
    /// Hyprland can composite per-pixel alpha, but `j/clients` cannot prove a
    /// particular surface is fully opaque.
    PerPixelSupportedOpacityUnknown,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum BlurCapability {
    /// Exact compositor blur includes content behind the window and therefore
    /// requires scene reconstruction rather than a standalone window texture.
    CompositorSceneRequired,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct WindowEffects {
    pub alpha: AlphaCapability,
    pub blur: BlurCapability,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum RoleEvidence {
    TiledOrFullscreenClient,
    FloatingClient,
}

#[derive(Clone, Debug, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct HyprMonitor {
    pub id: i64,
    pub name: String,
    #[serde(default)]
    pub description: String,
    pub width: f64,
    pub height: f64,
    #[serde(rename = "refreshRate")]
    pub refresh_rate: f64,
    pub x: f64,
    pub y: f64,
    pub scale: f64,
    #[serde(default)]
    pub transform: i32,
    #[serde(default)]
    pub disabled: bool,
}

impl HyprMonitor {
    /// Converts Hyprland monitor data to Viewflow DIP coordinates.
    ///
    /// Hyprland reports monitor `x/y` in compositor logical coordinates, while
    /// `width/height` are untransformed physical pixels.
    #[must_use]
    pub fn bounds_dip(&self) -> Rect {
        let (physical_width, physical_height) = if rotates_axes(self.transform) {
            (self.height, self.width)
        } else {
            (self.width, self.height)
        };
        Rect {
            origin: Point {
                x: self.x,
                y: self.y,
            },
            size: Size {
                width: physical_width / self.scale,
                height: physical_height / self.scale,
            },
        }
    }

    #[must_use]
    #[allow(clippy::cast_possible_truncation, clippy::cast_sign_loss)]
    pub fn refresh_millihz(&self) -> u32 {
        let millihz = (self.refresh_rate * 1000.0).round();
        if !millihz.is_finite() || millihz <= 0.0 {
            return 0;
        }
        millihz.min(f64::from(u32::MAX)) as u32
    }

    pub(crate) fn identity_material(&self) -> String {
        format!(
            "{}:{}:{}:{}:{}:{}:{}:{};",
            self.id,
            self.name,
            self.width,
            self.height,
            self.x,
            self.y,
            self.scale,
            self.refresh_millihz()
        )
    }
}

#[derive(Clone, Debug, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
#[allow(clippy::struct_excessive_bools)]
pub struct HyprWindow {
    pub address: String,
    #[serde(default)]
    pub mapped: bool,
    #[serde(default)]
    pub hidden: bool,
    #[serde(default)]
    pub visible: bool,
    pub at: [f64; 2],
    pub size: [f64; 2],
    #[serde(default)]
    pub floating: bool,
    #[serde(default)]
    pub monitor: i64,
    #[serde(default)]
    pub class: String,
    #[serde(default)]
    pub title: String,
    #[serde(default, rename = "initialClass")]
    pub initial_class: String,
    #[serde(default, rename = "initialTitle")]
    pub initial_title: String,
    #[serde(default)]
    pub pid: i64,
    #[serde(default)]
    pub xwayland: bool,
    #[serde(default)]
    pub fullscreen: u8,
    #[serde(default)]
    pub grouped: Vec<String>,
    #[serde(default, rename = "stableId")]
    pub stable_id: String,
}

impl HyprWindow {
    #[must_use]
    pub fn bounds_dip(&self) -> Rect {
        Rect {
            origin: Point {
                x: self.at[0],
                y: self.at[1],
            },
            size: Size {
                width: self.size[0],
                height: self.size[1],
            },
        }
    }

    pub(crate) fn to_record(
        &self,
        instance_signature: &str,
        source_device: DeviceId,
    ) -> HyprWindowRecord {
        let stable_window_key = if self.stable_id.is_empty() {
            self.address.as_str()
        } else {
            self.stable_id.as_str()
        };
        let pid = self.pid.to_string();
        let family_class = if self.initial_class.is_empty() {
            self.class.as_str()
        } else {
            self.initial_class.as_str()
        };
        let floating_utility = self.floating && self.fullscreen == 0;
        let (role, role_evidence) = if floating_utility {
            (WindowRole::Utility, RoleEvidence::FloatingClient)
        } else {
            (WindowRole::Main, RoleEvidence::TiledOrFullscreenClient)
        };

        HyprWindowRecord {
            descriptor: WindowDescriptor {
                id: ids::stable_id("hyprland-window", &[instance_signature, stable_window_key]),
                family_id: ids::stable_id(
                    "hyprland-window-family",
                    &[instance_signature, &pid, family_class],
                ),
                source_device,
                role,
                bounds_dip: self.bounds_dip(),
                min_size_dip: Size {
                    width: 1.0,
                    height: 1.0,
                },
                max_size_dip: None,
                // Conservative: omission would incorrectly treat alpha pixels as opaque.
                has_alpha: true,
                // j/clients has no reliable effective per-window blur radius.
                blur_radius_dip: None,
            },
            effects: WindowEffects {
                alpha: AlphaCapability::PerPixelSupportedOpacityUnknown,
                blur: BlurCapability::CompositorSceneRequired,
            },
            role_evidence,
            address: self.address.clone(),
            title: self.title.clone(),
            class: self.class.clone(),
        }
    }
}

/// Parses the response from Hyprland's `j/monitors` request.
///
/// # Errors
///
/// Returns a JSON error when the response does not match the Hyprland schema.
pub fn parse_monitors(json: &str) -> Result<Vec<HyprMonitor>, serde_json::Error> {
    serde_json::from_str(json)
}

/// Parses the response from Hyprland's `j/clients` request.
///
/// # Errors
///
/// Returns a JSON error when the response does not match the Hyprland schema.
pub fn parse_windows(json: &str) -> Result<Vec<HyprWindow>, serde_json::Error> {
    serde_json::from_str(json)
}

/// Converts a rectangle whose origin and size are both in physical pixels.
/// This is useful for capture-buffer coordinates; Hyprland layout coordinates
/// from `j/monitors` and `j/clients` are already logical and must not use it.
#[must_use]
pub fn physical_rect_to_dip(rect: Rect, scale: f64) -> Rect {
    Rect {
        origin: Point {
            x: rect.origin.x / scale,
            y: rect.origin.y / scale,
        },
        size: Size {
            width: rect.size.width / scale,
            height: rect.size.height / scale,
        },
    }
}

fn rotates_axes(transform: i32) -> bool {
    matches!(transform, 1 | 3 | 5 | 7)
}

#[cfg(test)]
mod tests {
    use super::*;
    use viewflow_protocol::Id128;

    const MONITORS: &str = include_str!("../tests/fixtures/monitors.json");
    const CLIENTS: &str = include_str!("../tests/fixtures/clients.json");

    #[test]
    fn parses_monitor_fixture_and_converts_physical_size_only() {
        let monitors = parse_monitors(MONITORS).unwrap();
        assert_eq!(monitors.len(), 3);
        assert_eq!(
            monitors[1].bounds_dip(),
            Rect {
                origin: Point { x: 1920.0, y: 0.0 },
                size: Size {
                    width: 1920.0,
                    height: 1080.0,
                },
            }
        );
        assert_eq!(monitors[1].refresh_millihz(), 60_000);

        // A 90-degree transform swaps physical axes before scale conversion.
        assert_eq!(
            monitors[2].bounds_dip().size,
            Size {
                width: 1280.0,
                height: 720.0
            }
        );
    }

    #[test]
    fn parses_clients_and_preserves_logical_window_geometry() {
        let windows = parse_windows(CLIENTS).unwrap();
        assert_eq!(windows.len(), 2);
        assert_eq!(
            windows[0].bounds_dip(),
            Rect {
                origin: Point { x: 120.0, y: 80.0 },
                size: Size {
                    width: 900.0,
                    height: 640.0
                },
            }
        );
    }

    #[test]
    fn window_records_have_stable_ids_roles_and_effect_markers() {
        let windows = parse_windows(CLIENTS).unwrap();
        let first = windows[0].to_record("fixture-instance", Id128(99));
        let again = windows[0].to_record("fixture-instance", Id128(99));
        assert_eq!(first.descriptor.id, again.descriptor.id);
        assert_eq!(first.descriptor.role, WindowRole::Main);
        assert!(first.descriptor.has_alpha);
        assert_eq!(first.descriptor.blur_radius_dip, None);
        assert_eq!(first.effects.blur, BlurCapability::CompositorSceneRequired);

        let utility = windows[1].to_record("fixture-instance", Id128(99));
        assert_eq!(utility.descriptor.role, WindowRole::Utility);
        assert_eq!(utility.role_evidence, RoleEvidence::FloatingClient);
    }

    #[test]
    fn converts_capture_pixel_coordinates_to_dip() {
        assert_eq!(
            physical_rect_to_dip(
                Rect {
                    origin: Point { x: 300.0, y: 150.0 },
                    size: Size {
                        width: 1200.0,
                        height: 900.0
                    },
                },
                1.5
            ),
            Rect {
                origin: Point { x: 200.0, y: 100.0 },
                size: Size {
                    width: 800.0,
                    height: 600.0
                },
            }
        );
    }
}
