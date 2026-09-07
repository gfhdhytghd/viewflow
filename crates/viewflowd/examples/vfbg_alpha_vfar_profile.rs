//! Offline VFAR alpha profiling for one bounded VFBG or VFAR v1 fixture.
//! This reads the fixture and prints statistics only; it never writes image data.

use anyhow::{Context, Result, ensure};
use bytes::Bytes;
use sha2::{Digest, Sha256};
use std::{fs::File, io::Read, time::Instant};
use viewflow_transport::{AlphaRleLimits, RawBgraPayload, decode_alpha_rle, encode_alpha_rle};

const HEADER_BYTES: usize = 20;
const MAX_PIXEL_BYTES: usize = 64 * 1024 * 1024;

fn main() -> Result<()> {
    let mut arguments = std::env::args().skip(1);
    let path = arguments.next().context(
        "usage: cargo run -p viewflowd --example vfbg_alpha_vfar_profile -- VFBG_OR_VFAR_FILE",
    )?;
    ensure!(
        arguments.next().is_none(),
        "accepts exactly one VFBG_OR_VFAR_FILE"
    );
    let (format, fixture, alpha) = read_input(&path)?;
    let limits = AlphaRleLimits {
        max_coded_width: fixture.width,
        max_coded_height: fixture.height,
        max_luma_samples: alpha.len() as u64,
        max_decoded_bytes: alpha.len() as u64,
        max_encoded_bytes: MAX_PIXEL_BYTES + 24,
    };
    let encode_started = Instant::now();
    let encoded = encode_alpha_rle(fixture.width, fixture.height, &alpha)?;
    let encode_us = encode_started.elapsed().as_micros();
    let decode_started = Instant::now();
    let decoded = decode_alpha_rle(encoded.clone(), limits)?;
    let decode_us = decode_started.elapsed().as_micros();
    ensure!(
        decoded.samples.as_ref() == alpha,
        "VFAR roundtrip changed alpha bytes"
    );
    println!(
        "format={} fixture_sha256={} width={} height={} stride={} alpha_bytes={} vfar_bytes={} encode_us={} decode_us={} roundtrip=exact",
        format,
        fixture.sha256,
        fixture.width,
        fixture.height,
        fixture.stride,
        alpha.len(),
        encoded.len(),
        encode_us,
        decode_us
    );
    Ok(())
}

struct Fixture {
    width: u32,
    height: u32,
    stride: u32,
    pixels: Bytes,
    sha256: String,
}

fn read_input(path: &str) -> Result<(&'static str, Fixture, Bytes)> {
    let (bytes, sha256) = read_bounded_regular_file(path)?;
    if bytes.starts_with(b"VFBG") {
        let payload = RawBgraPayload::decode(Bytes::from(bytes), MAX_PIXEL_BYTES)
            .context("strict VFBG header, stride, size, and premultiplication validation")?;
        let fixture = Fixture {
            width: payload.width,
            height: payload.height,
            stride: payload.stride,
            pixels: payload.pixels,
            sha256,
        };
        let alpha = extract_alpha(&fixture)?;
        return Ok(("VFBG", fixture, Bytes::from(alpha)));
    }
    ensure!(bytes.starts_with(b"VFAR"), "input must be VFBG or VFAR v1");
    let decoded = decode_alpha_rle(
        Bytes::from(bytes),
        AlphaRleLimits {
            max_coded_width: 8192,
            max_coded_height: 8192,
            max_luma_samples: MAX_PIXEL_BYTES as u64,
            max_decoded_bytes: MAX_PIXEL_BYTES as u64,
            max_encoded_bytes: MAX_PIXEL_BYTES,
        },
    )
    .context("strict bounded VFAR v1 decode")?;
    Ok((
        "VFAR",
        Fixture {
            width: decoded.width,
            height: decoded.height,
            stride: decoded.width,
            pixels: Bytes::new(),
            sha256,
        },
        decoded.samples,
    ))
}

fn read_bounded_regular_file(path: &str) -> Result<(Vec<u8>, String)> {
    let metadata = std::fs::metadata(path).with_context(|| format!("stat {path}"))?;
    ensure!(
        metadata.file_type().is_file(),
        "VFBG input must be a regular file"
    );
    let length = usize::try_from(metadata.len()).context("VFBG length does not fit usize")?;
    ensure!(
        (HEADER_BYTES..=MAX_PIXEL_BYTES + 24).contains(&length),
        "VFBG file length is outside bounded limit"
    );
    let file = File::open(path).with_context(|| format!("open {path}"))?;
    ensure!(
        file.metadata()?.file_type().is_file(),
        "VFBG input changed to a non-regular file"
    );
    let mut bytes = Vec::with_capacity(length);
    file.take(u64::try_from(length + 1)?)
        .read_to_end(&mut bytes)?;
    ensure!(bytes.len() == length, "VFBG file changed while it was read");
    let sha256 = format!("{:x}", Sha256::digest(&bytes));
    Ok((bytes, sha256))
}

fn extract_alpha(fixture: &Fixture) -> Result<Vec<u8>> {
    let width = usize::try_from(fixture.width)?;
    let height = usize::try_from(fixture.height)?;
    let stride = usize::try_from(fixture.stride)?;
    let row = width.checked_mul(4).context("VFBG row overflow")?;
    ensure!(stride >= row, "VFBG stride is smaller than active BGRA row");
    ensure!(
        stride.checked_mul(height) == Some(fixture.pixels.len()),
        "VFBG payload size does not match stride times height"
    );
    let mut alpha = Vec::with_capacity(width.checked_mul(height).context("alpha size overflow")?);
    for row_bytes in fixture.pixels.chunks_exact(stride) {
        alpha.extend(row_bytes[..row].chunks_exact(4).map(|pixel| pixel[3]));
    }
    ensure!(alpha.len() == width * height, "incomplete alpha extraction");
    Ok(alpha)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    #[test]
    fn extracts_alpha_from_a_padded_validated_vfbg_payload() {
        let fixture = Fixture {
            width: 2,
            height: 1,
            stride: 12,
            pixels: Bytes::from_static(&[1, 2, 3, 4, 5, 6, 7, 8, 0, 0, 0, 0]),
            sha256: String::new(),
        };
        assert_eq!(extract_alpha(&fixture).unwrap(), [4, 8]);
    }

    #[test]
    fn rejects_a_vfbg_stride_smaller_than_the_active_bgra_row() {
        let mut fixture = tempfile::NamedTempFile::new().unwrap();
        fixture
            .write_all(b"VFBG\x01\x01\0\0\0\0\0\x01\0\0\0\x01\0\0\0\x03\0\0\0")
            .unwrap();
        assert!(read_input(fixture.path().to_str().unwrap()).is_err());
    }

    fn vfar_header(mode: u8, width: u32, height: u32, declared_bytes: u64) -> Vec<u8> {
        let mut output = b"VFAR\x01".to_vec();
        output.push(mode);
        output.extend_from_slice(&[0, 0]);
        output.extend_from_slice(&width.to_be_bytes());
        output.extend_from_slice(&height.to_be_bytes());
        output.extend_from_slice(&declared_bytes.to_be_bytes());
        output
    }

    #[test]
    fn rejects_invalid_bounded_vfar_forms() {
        let cases = [
            vfar_header(1, 1, 1, 1), // truncated RLE payload
            {
                let mut value = vfar_header(1, 1, 1, 1);
                value.extend_from_slice(&[0x81, 7]); // run length two overflows one sample
                value
            },
            {
                let mut value = vfar_header(1, 1, 1, 1);
                value.extend_from_slice(&[0, 7, 9]); // valid literal plus trailing byte
                value
            },
            {
                let mut value = vfar_header(0, 1, 1, 1);
                value[4] = 2;
                value.push(7);
                value
            },
            vfar_header(0, 8193, 1, 8193),
        ];
        for case in cases {
            let mut fixture = tempfile::NamedTempFile::new().unwrap();
            fixture.write_all(&case).unwrap();
            assert!(read_input(fixture.path().to_str().unwrap()).is_err());
        }
    }
}
