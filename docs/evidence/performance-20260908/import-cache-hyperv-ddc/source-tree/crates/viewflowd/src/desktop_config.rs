//! Explicit local policy for the cross-device desktop bridge.
use anyhow::{Context, Result, ensure};
use serde::{Deserialize, Serialize};
use std::path::PathBuf;
use viewflow_protocol::DesktopRect;

/// A monitor in the shared desktop: physical resolution, pixels per logical
/// pixel, and a global logical origin. Scale 1.5 means 150%, like Hyprland.
#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct AtlasDisplayConfig {
    pub width: u32,
    pub height: u32,
    pub scale: f64,
    pub x: i32,
    pub y: i32,
}

impl AtlasDisplayConfig {
    /// # Errors
    /// Requires a finite scale between 0.125 and 8 with at most three decimal
    /// places. The integer ratio avoids an approximate inverse for 1.5x DPI.
    pub fn scale_milli(self) -> Result<u32> {
        let scaled = self.scale * 1000.0;
        ensure!(
            self.scale.is_finite()
                && (125.0..=8000.0).contains(&scaled)
                && (scaled - scaled.round()).abs() < 0.000_001,
            "display scale must be 0.125..8, with at most three decimal places"
        );
        #[allow(clippy::cast_possible_truncation, clippy::cast_sign_loss)]
        Ok(scaled.round() as u32)
    }

    /// # Errors
    /// Rejects empty or unbounded physical resolutions and global rectangles.
    pub fn rect(self) -> Result<DesktopRect> {
        ensure!(
            (1..=32768).contains(&self.width) && (1..=32768).contains(&self.height),
            "display resolution must be 1..32768 physical pixels per axis"
        );
        let scale = u64::from(self.scale_milli()?);
        let rect = DesktopRect {
            x_millidip: i64::from(self.x) * 1000,
            y_millidip: i64::from(self.y) * 1000,
            width_millidip: u64::from(self.width) * 1_000_000 / scale,
            height_millidip: u64::from(self.height) * 1_000_000 / scale,
        };
        rect.validate()
            .map_err(|e| anyhow::anyhow!("invalid display bounds: {e:?}"))?;
        Ok(rect)
    }
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct AtlasDesktopCandidate {
    pub address: String,
    pub pid: u32,
    pub stable_id: String,
}

fn default_capacity() -> usize {
    8
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct AtlasSourceDesktopConfig {
    pub topology_generation: u64,
    pub local_display: AtlasDisplayConfig,
    pub remote_display: AtlasDisplayConfig,
    pub hyprland_socket: PathBuf,
    pub native_control_dir: PathBuf,
    #[serde(default)]
    pub auto_enroll: bool,
    #[serde(default = "default_capacity")]
    pub max_enrolled_windows: usize,
    #[serde(default)]
    pub candidates: Vec<AtlasDesktopCandidate>,
}

impl AtlasSourceDesktopConfig {
    /// # Errors
    /// Requires disjoint coordinate-configured displays, bounded local enrollment and exact
    /// local IPC paths. Actual path ownership is checked when opening the IPC.
    pub fn validate(&self, max_tiles: usize) -> Result<()> {
        let local = self.local_display.rect()?;
        let remote = self.remote_display.rect()?;
        let lr = local.x_millidip + i64::try_from(local.width_millidip)?;
        let lb = local.y_millidip + i64::try_from(local.height_millidip)?;
        let rr = remote.x_millidip + i64::try_from(remote.width_millidip)?;
        let rb = remote.y_millidip + i64::try_from(remote.height_millidip)?;
        ensure!(
            lr <= remote.x_millidip
                || rr <= local.x_millidip
                || lb <= remote.y_millidip
                || rb <= local.y_millidip,
            "configured displays overlap in global logical coordinates"
        );
        ensure!(
            self.topology_generation > 0,
            "desktop topology generation is zero"
        );
        ensure!(
            (1..=8).contains(&self.max_enrolled_windows)
                && self.max_enrolled_windows <= max_tiles
                && self.candidates.len() <= self.max_enrolled_windows,
            "desktop enrollment capacity invalid"
        );
        ensure!(
            self.hyprland_socket.is_absolute()
                && self.hyprland_socket.as_os_str().len() < 108
                && self.native_control_dir.is_absolute(),
            "desktop requires absolute local IPC paths"
        );
        let mut addresses = std::collections::BTreeSet::new();
        for candidate in &self.candidates {
            let address = candidate
                .address
                .strip_prefix("0x")
                .context("desktop address needs 0x")?;
            ensure!(
                !address.is_empty()
                    && address.len() <= 16
                    && address.bytes().all(|b| b.is_ascii_hexdigit()),
                "invalid desktop candidate address"
            );
            let address = u64::from_str_radix(address, 16)?;
            ensure!(
                address != 0
                    && addresses.insert(address)
                    && candidate.pid > 0
                    && !candidate.stable_id.is_empty()
                    && candidate.stable_id.len() <= 128,
                "invalid/duplicate desktop candidate identity"
            );
        }
        Ok(())
    }
}

#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct AtlasReceiverDesktopConfig {
    pub display: AtlasDisplayConfig,
    /// Physical origin on the receiving OS, independent of the shared canvas.
    #[serde(default)]
    pub native_x: i32,
    #[serde(default)]
    pub native_y: i32,
}

impl AtlasReceiverDesktopConfig {
    /// # Errors
    /// Rejects unbounded native placement or invalid monitor configuration.
    pub fn validate(self) -> Result<()> {
        self.display.rect()?;
        ensure!(
            self.native_x.unsigned_abs() <= 1_000_000 && self.native_y.unsigned_abs() <= 1_000_000,
            "invalid native display origin"
        );
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn monitor_scale_and_negative_origin_define_logical_bounds() {
        let display = AtlasDisplayConfig {
            width: 1920,
            height: 1080,
            scale: 1.5,
            x: -1280,
            y: -20,
        };
        let rect = display.rect().unwrap();
        assert_eq!(rect.x_millidip, -1_280_000);
        assert_eq!(rect.y_millidip, -20_000);
        assert_eq!(rect.width_millidip, 1_280_000);
        assert_eq!(rect.height_millidip, 720_000);
        assert_eq!(display.scale_milli().unwrap(), 1500);
        assert!(
            AtlasDisplayConfig {
                width: 0,
                ..display
            }
            .rect()
            .is_err()
        );
        for scale in [0.0, -1.0, f64::NAN, f64::INFINITY, 8.001, 1.2345] {
            assert!(AtlasDisplayConfig { scale, ..display }.rect().is_err());
        }
    }

    #[test]
    fn fractional_logical_size_uses_same_integer_ratio_as_presenter() {
        let display = AtlasDisplayConfig {
            width: 2560,
            height: 1440,
            scale: 1.5,
            x: 0,
            y: 0,
        };
        let rect = display.rect().unwrap();
        assert_eq!(rect.width_millidip, 1_706_666);
        assert_eq!(rect.height_millidip, 960_000);
    }

    #[test]
    fn topology_uses_rectangles_in_every_direction_and_allows_gaps() {
        let display = AtlasDisplayConfig {
            width: 1920,
            height: 1080,
            scale: 1.5,
            x: 0,
            y: 0,
        };
        let mut config = AtlasSourceDesktopConfig {
            topology_generation: 1,
            local_display: display,
            remote_display: display,
            hyprland_socket: std::env::temp_dir().join("viewflow-layout.sock"),
            native_control_dir: std::env::temp_dir().join("viewflow-layout-control"),
            auto_enroll: true,
            max_enrolled_windows: 8,
            candidates: vec![],
        };
        for (x, y) in [
            (-1280, 30),
            (1280, -200),
            (200, -720),
            (-300, 720),
            (2000, 2000),
        ] {
            config.remote_display.x = x;
            config.remote_display.y = y;
            config.validate(8).unwrap();
        }
        config.remote_display.x = 1279;
        config.remote_display.y = 0;
        assert!(config.validate(8).is_err());
    }

    #[test]
    fn old_edge_or_inverse_scale_fields_are_not_display_configuration() {
        for json in [
            r#"{"width":1920,"height":1080,"scale":1.5,"x":0,"y":0,"edge":"left"}"#,
            r#"{"width":1920,"height":1080,"scale_millidip_per_pixel":667,"x":0,"y":0}"#,
        ] {
            assert!(serde_json::from_str::<AtlasDisplayConfig>(json).is_err());
        }
    }
}
