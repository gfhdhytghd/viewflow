//! Generate synthetic paired Annex-B samples for native decoder validation.
//! Does not capture the desktop or connect to a peer.

#[cfg(all(target_os = "linux", feature = "native-nvenc"))]
fn main() -> Result<(), Box<dyn std::error::Error>> {
    use std::{
        fs::OpenOptions,
        io::Write,
        os::unix::fs::{DirBuilderExt, OpenOptionsExt},
        path::PathBuf,
    };
    use viewflowd::nvenc_runtime::{
        AlphaFidelity, AlphaPolicy, Encoder, EncoderConfig, FrameMetadata,
    };

    let mut args = std::env::args_os().skip(1);
    let destination = PathBuf::from(args.next().ok_or("expected fresh output directory")?);
    let parse_dimension = |name: &str,
                           value: Option<std::ffi::OsString>|
     -> Result<u32, Box<dyn std::error::Error>> {
        match value {
            Some(value) => value
                .into_string()
                .map_err(|_| format!("{name} must be UTF-8"))?
                .parse::<u32>()
                .map_err(|_| format!("invalid {name}").into()),
            None => Ok(256),
        }
    };
    let width = parse_dimension("width", args.next())?;
    let height = parse_dimension("height", args.next())?;
    if args.next().is_some() || width == 0 || height == 0 || width % 2 != 0 || height % 2 != 0 {
        return Err(
            "usage: nvenc_decode_fixture <fresh-output-dir> [even-width even-height]".into(),
        );
    }
    let pixels = usize::try_from(
        u64::from(width)
            .checked_mul(u64::from(height))
            .ok_or("fixture geometry overflow")?,
    )?;
    let max_access_unit_bytes = if pixels > 256 * 256 {
        8 * 1024 * 1024
    } else {
        1024 * 1024
    };
    let max_record_bytes = 16 * 1024 * 1024;
    let mut encoder = Encoder::new(EncoderConfig {
        width,
        height,
        max_access_unit_bytes,
        max_pending_frames: 8,
        alpha_policy: AlphaPolicy::Required,
        alpha_fidelity: AlphaFidelity::Lossless,
    })?;
    let mut outputs = Vec::new();
    let mut expected_alpha = Vec::new();
    for frame_id in 1..=3_u64 {
        let mut rgba = vec![0; pixels * 4];
        for (i, pixel) in rgba.chunks_exact_mut(4).enumerate() {
            let alpha = u8::try_from((i + usize::try_from(frame_id)? * 17) % 256)?;
            let x = i % usize::try_from(width)?;
            let y = i / usize::try_from(width)?;
            pixel.copy_from_slice(&[u8::try_from(x % 256)?, u8::try_from(y % 256)?, 128, alpha]);
            expected_alpha.push(alpha);
        }
        outputs.extend(encoder.submit(
            &rgba,
            FrameMetadata {
                frame_id,
                timestamp_ns: frame_id * 16_666_667,
                geometry_epoch: 1,
            },
            frame_id == 1,
        )?);
    }
    outputs.extend(encoder.drain()?);
    if outputs.len() != 3 {
        return Err("missing encoded frames".into());
    }
    std::fs::DirBuilder::new()
        .mode(0o700)
        .create(&destination)?;
    let save = |name: &str, bytes: &[u8]| -> std::io::Result<()> {
        let mut file = OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(destination.join(name))?;
        file.write_all(bytes)?;
        file.sync_all()
    };
    let mut color = Vec::new();
    let mut alpha = Vec::new();
    let mut presenter = Vec::new();
    let mut presenter_v2 = Vec::new();
    for output in outputs {
        let alpha_offset = usize::try_from(
            output
                .metadata
                .frame_id
                .checked_sub(1)
                .ok_or("zero fixture identity")?,
        )?
        .checked_mul(pixels)
        .ok_or("fixture alpha offset overflow")?;
        let frame_alpha = expected_alpha
            .get(alpha_offset..alpha_offset + pixels)
            .ok_or("fixture output identity has no matching alpha")?;
        let vfar = viewflow_transport::encode_alpha_rle(width, height, frame_alpha)?;
        presenter_v2.extend(
            viewflowd::gpu_presenter_pipe::encode_compressed_alpha_record(
                output.metadata.frame_id,
                width,
                height,
                &output.color_annex_b,
                &vfar,
                max_record_bytes,
            )?,
        );
        presenter.extend(viewflowd::gpu_presenter_pipe::encode_record(
            output.metadata.frame_id,
            width,
            height,
            &output.color_annex_b,
            frame_alpha,
            max_record_bytes,
        )?);
        save(
            &format!("color-{}.h264", output.metadata.frame_id),
            &output.color_annex_b,
        )?;
        save(
            &format!("alpha-{}.h264", output.metadata.frame_id),
            &output.alpha_annex_b,
        )?;
        color.extend_from_slice(&output.color_annex_b);
        alpha.extend_from_slice(&output.alpha_annex_b);
    }
    save("color.h264", &color)?;
    save("alpha.h264", &alpha)?;
    save("expected-alpha.gray", &expected_alpha)?;
    save("presenter.vfgp", &presenter)?;
    save("presenter-v2.vfgp", &presenter_v2)?;
    println!(
        "synthetic {}x{}, 3 frames; color={} alpha={} expected_alpha={}",
        width,
        height,
        color.len(),
        alpha.len(),
        expected_alpha.len()
    );
    Ok(())
}

#[cfg(not(all(target_os = "linux", feature = "native-nvenc")))]
fn main() {
    eprintln!("requires Linux and --features native-nvenc");
    std::process::exit(2);
}
