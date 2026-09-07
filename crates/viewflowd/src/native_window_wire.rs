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
            u32_at(0) == 2 && u64_at(12) > 0 && (1..=11).contains(&u32_at(20)),
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
            ensure!(
                tile.id > 0
                    && seen.insert(tile.id)
                    && tile.width > 0
                    && tile.height > 0
                    && tile.width <= self.width
                    && tile.height <= self.height
                    && tile.atlas_x <= self.width - tile.width
                    && tile.atlas_y <= self.height - tile.height
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
            bytes.extend(0u32.to_le_bytes());
            bytes.extend(tile.geometry_ack.to_le_bytes());
        }
        blob(&mut bytes, &alpha(self.raw_alpha));
        blob(&mut bytes, self.color);
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
