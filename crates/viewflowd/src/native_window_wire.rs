//! Portable adapter for platform/reverse-common/wire.hpp (VFRV version 1).
use anyhow::{Result, ensure};
use std::io::{Read, Write};

pub const MAX_RECORD: usize = 96 * 1024 * 1024;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Input {
    pub id: u64,
    pub sequence: u64,
    pub kind: u32,
    pub a: i32,
    pub b: i32,
    pub c: i32,
    pub d: i32,
}

impl Input {
    pub fn decode(bytes: &[u8]) -> Result<Self> {
        ensure!(bytes.len() == 40, "native window input length");
        let u32_at = |i| u32::from_le_bytes(bytes[i..i + 4].try_into().unwrap());
        let u64_at = |i| u64::from_le_bytes(bytes[i..i + 8].try_into().unwrap());
        ensure!(
            u32_at(0) == 2 && u64_at(12) > 0 && (1..=16).contains(&u32_at(20)),
            "native window input identity"
        );
        Ok(Self {
            id: u64_at(4),
            sequence: u64_at(12),
            kind: u32_at(20),
            a: u32_at(24) as i32,
            b: u32_at(28) as i32,
            c: u32_at(32) as i32,
            d: u32_at(36) as i32,
        })
    }
    pub fn encode(self) -> Vec<u8> {
        let mut bytes = 2u32.to_le_bytes().to_vec();
        bytes.extend(self.id.to_le_bytes());
        bytes.extend(self.sequence.to_le_bytes());
        bytes.extend(self.kind.to_le_bytes());
        for n in [self.a, self.b, self.c, self.d] {
            bytes.extend(n.to_le_bytes());
        }
        bytes
    }
}

#[derive(Clone, Debug)]
pub struct Tile {
    pub id: u64,
    pub x: i32,
    pub y: i32,
    pub width: u32,
    pub height: u32,
    pub atlas_x: u32,
    pub atlas_y: u32,
    pub title: String,
    pub geometry_ack: u64,
    pub flags: u32,
    pub resident: Option<[u32; 4]>,
    pub application_icon: Option<(String, Vec<u8>)>,
}

#[cfg(unix)]
pub fn source_application_icon(app_id: &str) -> Option<(String, Vec<u8>)> {
    crate::window_icon::resolve(viewflow_protocol::Id128(1), app_id).map(|icon| (icon.app_id, icon.png))
}

pub struct Frame<'a> {
    pub width: u32,
    pub height: u32,
    pub pts: u64,
    pub keyframe: bool,
    pub tiles: &'a [Tile],
    pub raw_alpha: &'a [u8],
    pub color: &'a [u8],
}

impl Frame<'_> {
    pub fn encode(&self) -> Result<Vec<u8>> {
        self.encode_with_blur(None)
    }
    pub fn encode_with_blur(
        &self,
        blur: Option<&crate::native_window_blur::BlurRecipe>,
    ) -> Result<Vec<u8>> {
        ensure!(
            self.width > 0
                && self.height > 0
                && self.width <= 8192
                && self.height <= 8192
                && u64::from(self.width) * u64::from(self.height) <= 32 * 1024 * 1024
                && self.raw_alpha.len() == self.width as usize * self.height as usize
                && !self.color.is_empty()
                && self.color.len() <= 32 * 1024 * 1024
                && self.pts <= i64::MAX as u64
                && self.tiles.len() <= 32,
            "native window frame extent"
        );
        let mut seen = std::collections::BTreeSet::new();
        let mut bytes = Vec::new();
        for n in [1u32, 1, self.width, self.height] {
            bytes.extend(n.to_le_bytes());
        } // H.264
        bytes.extend(self.pts.to_le_bytes());
        bytes.extend(u32::from(self.keyframe).to_le_bytes());
        bytes.extend((self.tiles.len() as u32).to_le_bytes());
        for tile in self.tiles {
            let [rx, ry, rw, rh] = tile.resident.unwrap_or([0, 0, tile.width, tile.height]);
            ensure!(
                tile.id > 0
                    && seen.insert(tile.id)
                    && tile.width > 0
                    && tile.height > 0
                    && rx <= tile.width && rw <= tile.width - rx
                    && ry <= tile.height && rh <= tile.height - ry
                    && rw <= self.width && rh <= self.height
                    && tile.atlas_x <= self.width - rw
                    && tile.atlas_y <= self.height - rh
                    && tile.title.len() <= 4096,
                "native window tile extent"
            );
            bytes.extend(tile.id.to_le_bytes());
            bytes.extend(0u64.to_le_bytes());
            bytes.extend(tile.x.to_le_bytes());
            bytes.extend(tile.y.to_le_bytes());
            for n in [tile.width, tile.height, tile.atlas_x, tile.atlas_y] {
                bytes.extend(n.to_le_bytes());
            }
            blob(&mut bytes, tile.title.as_bytes());
            bytes.extend(((tile.flags & !(256 | 1024)) | if tile.resident.is_some() {256} else {0} | if tile.application_icon.is_some() {1024} else {0}).to_le_bytes());
            bytes.extend(tile.geometry_ack.to_le_bytes());
            if tile.resident.is_some() {
                for value in [rx, ry, rw, rh] { bytes.extend(value.to_le_bytes()); }
            }
            if let Some((app_id, png)) = &tile.application_icon {
                viewflow_protocol::ApplicationIcon { window_id: viewflow_protocol::Id128(tile.id.into()), app_id: app_id.clone(), png: png.clone() }
                    .dimensions().map_err(|e| anyhow::anyhow!("native application icon: {e:?}"))?;
                blob(&mut bytes, app_id.as_bytes());blob(&mut bytes, png);
            }
        }
        blob(&mut bytes, &alpha(self.raw_alpha));
        if let Some(blur) = blur {
            let mut color = blur.h264_sei()?;
            color.extend(self.color);
            ensure!(
                color.len() <= 32 * 1024 * 1024,
                "native color with blur metadata too large"
            );
            blob(&mut bytes, &color);
        } else {
            blob(&mut bytes, self.color);
        }
        ensure!(bytes.len() <= MAX_RECORD, "native window record too large");
        Ok(bytes)
    }
}

fn blob(out: &mut Vec<u8>, bytes: &[u8]) {
    out.extend((bytes.len() as u32).to_le_bytes());
    out.extend(bytes);
}
fn alpha(raw: &[u8]) -> Vec<u8> {
    let mut bytes = vec![1];
    let mut at = 0;
    while at < raw.len() {
        let mut end = at + 1;
        while end < raw.len() && raw[end] == raw[at] {
            end += 1;
        }
        bytes.extend(((end - at) as u32).to_le_bytes());
        bytes.push(raw[at]);
        at = end;
        if bytes.len() > raw.len() {
            bytes.clear();
            bytes.push(0);
            bytes.extend(raw);
            break;
        }
    }
    bytes
}

pub fn read_input(reader: &mut impl Read) -> Result<Option<Input>> {
    let mut prefix = [0; 4];
    let count = reader.read(&mut prefix[..1])?;
    if count == 0 {
        return Ok(None);
    }
    reader.read_exact(&mut prefix[1..])?;
    ensure!(
        u32::from_le_bytes(prefix) == 40,
        "native window input record length"
    );
    let mut bytes = [0; 40];
    reader.read_exact(&mut bytes)?;
    Input::decode(&bytes).map(Some)
}
pub fn write_record(writer: &mut impl Write, record: &[u8]) -> Result<()> {
    ensure!(record.len() <= MAX_RECORD, "native window record too large");
    writer.write_all(&(record.len() as u32).to_le_bytes())?;
    writer.write_all(record)?;
    writer.flush()?;
    Ok(())
}

#[cfg(test)]
mod tests {
    #[test]
    fn visibility_and_geometry_control_roundtrip() {
        for kind in [15, 16] {
            let event = super::Input { id: 1, sequence: 1, kind, a: 200, b: 10, c: 400, d: 300 };
            assert_eq!(super::Input::decode(&event.encode()).unwrap(), event);
        }
    }
    #[test]
    fn cropped_tile_keeps_full_geometry_and_appends_resident_fields() {
        let mut tile = super::Tile { id: 1, x: -20, y: 30, width: 800, height: 600,
            atlas_x: 0, atlas_y: 0, title: String::new(), geometry_ack: 1, flags: 0,
            resident: Some([400, 300, 2, 2]), application_icon: None };
        let encode = |tile: &super::Tile| super::Frame { width: 2, height: 2, pts: 1, keyframe: true,
            tiles: std::slice::from_ref(tile), raw_alpha: &[255; 4], color: &[0, 0, 1, 0x65] }.encode();
        let bytes = encode(&tile).unwrap();
        assert_eq!(u32::from_le_bytes(bytes[56..60].try_into().unwrap()), 800);
        assert_eq!(u32::from_le_bytes(bytes[76..80].try_into().unwrap()), 256);
        assert_eq!(u32::from_le_bytes(bytes[88..92].try_into().unwrap()), 400);
        tile.resident = Some([0; 4]);
        assert!(encode(&tile).is_ok());
        tile.resident = Some([799, 0, 2, 1]);
        assert!(encode(&tile).is_err());
    }

    use super::*;
    #[test]
    fn input_preserves_negative_coordinates_and_sequence() {
        let event = Input {
            id: 9,
            sequence: 42,
            kind: 1,
            a: -400,
            b: 700,
            c: 1,
            d: 0,
        };
        assert_eq!(Input::decode(&event.encode()).unwrap(), event);
        let mut bytes = Vec::new();
        write_record(&mut bytes, &event.encode()).unwrap();
        assert_eq!(read_input(&mut bytes.as_slice()).unwrap(), Some(event));
        bytes[0] = 41;
        assert!(read_input(&mut bytes.as_slice()).is_err());
    }
    #[test]
    fn alpha_matches_cpp_raw_and_rle_contract() {
        assert_eq!(alpha(&[1, 2, 3]), vec![0, 1, 2, 3]);
        assert_eq!(alpha(&[7; 20]), vec![1, 20, 0, 0, 0, 7]);
    }
    #[test]
    fn frame_header_is_little_endian_reverse_v1() {
        let bytes = Frame {
            width: 2,
            height: 2,
            pts: 1,
            keyframe: true,
            tiles: &[],
            raw_alpha: &[0; 4],
            color: &[0, 0, 0, 1, 0x65],
        }
        .encode()
        .unwrap();
        assert_eq!(&bytes[..8], &[1, 0, 0, 0, 1, 0, 0, 0]);
        assert_eq!(&bytes[24..32], &[1, 0, 0, 0, 0, 0, 0, 0]);
    }
}
