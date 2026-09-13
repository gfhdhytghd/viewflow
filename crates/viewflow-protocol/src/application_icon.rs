use crate::{WindowId, WireError, required_id, wire};

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ApplicationIcon {
    pub window_id: WindowId,
    pub app_id: String,
    pub png: Vec<u8>,
}

impl ApplicationIcon {
    pub fn dimensions(&self) -> Result<(u32, u32), WireError> {
        if self.window_id.0 == 0
            || self.app_id.is_empty()
            || self.app_id.len() > 256
            || self.app_id.chars().any(char::is_control)
            || self.png.len() < 33
            || self.png.len() > 256 * 1024
            || &self.png[..8] != b"\x89PNG\r\n\x1a\n"
            || self.png[8..12] != 13u32.to_be_bytes()
            || &self.png[12..16] != b"IHDR"
        {
            return Err(WireError::InvalidField("application_icon"));
        }
        let width = u32::from_be_bytes(self.png[16..20].try_into().unwrap());
        let height = u32::from_be_bytes(self.png[20..24].try_into().unwrap());
        if !(1..=256).contains(&width) || !(1..=256).contains(&height) {
            return Err(WireError::InvalidField("application_icon.dimensions"));
        }
        Ok((width, height))
    }
}
impl TryFrom<wire::ApplicationIcon> for ApplicationIcon {
    type Error = WireError;
    fn try_from(value: wire::ApplicationIcon) -> Result<Self, Self::Error> {
        let icon = Self {
            window_id: required_id(value.window_id, "application_icon.window_id")?,
            app_id: value.app_id,
            png: value.png,
        };
        icon.dimensions()?;
        Ok(icon)
    }
}
impl From<ApplicationIcon> for wire::ApplicationIcon {
    fn from(value: ApplicationIcon) -> Self {
        Self {
            window_id: Some(wire::Id128 {
                high: (value.window_id.0 >> 64) as u64,
                low: value.window_id.0 as u64,
            }),
            app_id: value.app_id,
            png: value.png,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn icon_metadata_is_bounded_and_roundtrips_without_changing_pixels() {
        let mut png = b"\x89PNG\r\n\x1a\n".to_vec();
        png.extend(13u32.to_be_bytes());
        png.extend(b"IHDR");
        png.extend(256u32.to_be_bytes());
        png.extend(128u32.to_be_bytes());
        png.extend([8, 6, 0, 0, 0, 0, 0, 0, 0]);
        let icon = ApplicationIcon {
            window_id: crate::Id128(7),
            app_id: "kitty".into(),
            png,
        };
        assert_eq!(icon.dimensions().unwrap(), (256, 128));
        assert_eq!(
            ApplicationIcon::try_from(wire::ApplicationIcon::from(icon.clone())).unwrap(),
            icon
        );
        let mut oversized = icon.clone();
        oversized.png[16..20].copy_from_slice(&257u32.to_be_bytes());
        assert!(oversized.dimensions().is_err());
        let mut malformed = icon.clone();
        malformed.png[12] = 0;
        assert!(malformed.dimensions().is_err());
        let mut unbounded = icon;
        unbounded.png.resize(256 * 1024 + 1, 0);
        assert!(unbounded.dimensions().is_err());
    }
}
