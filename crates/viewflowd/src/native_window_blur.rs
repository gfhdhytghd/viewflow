//! Effective Hyprland blur recipe carried as ignorable H.264 SEI metadata.
use anyhow::{Context, Result, ensure};
#[cfg(target_os = "linux")]
use viewflow_hyprland::HyprIpcClient;

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct BlurRecipe {
    pub enabled: bool,
    pub size: u32,
    pub passes: u32,
    pub contrast: f32,
    pub brightness: f32,
    pub noise: f32,
    pub vibrancy: f32,
    pub vibrancy_darkness: f32,
}
impl BlurRecipe {
    #[cfg(target_os = "linux")]
    pub fn read(ipc: &HyprIpcClient) -> Result<Self> {
        let get = |key: &str, field: &str| -> Result<serde_json::Value> {
            let value: serde_json::Value =
                serde_json::from_str(&ipc.request(&format!("j/getoption decoration:blur:{key}"))?)?;
            value
                .get(field)
                .cloned()
                .with_context(|| format!("blur option {key} missing {field}"))
        };
        let integer = |key| -> Result<u32> {
            u32::try_from(get(key, "int")?.as_u64().context("blur integer")?)
                .context("blur integer range")
        };
        let float =
            |key| -> Result<f32> { Ok(get(key, "float")?.as_f64().context("blur float")? as f32) };
        let recipe = Self {
            enabled: get("enabled", "bool")?.as_bool().context("blur boolean")?,
            size: integer("size")?,
            passes: integer("passes")?,
            contrast: float("contrast")?,
            brightness: float("brightness")?,
            noise: float("noise")?,
            vibrancy: float("vibrancy")?,
            vibrancy_darkness: float("vibrancy_darkness")?,
        };
        recipe.validate()?;
        Ok(recipe)
    }
    fn validate(&self) -> Result<()> {
        ensure!(
            self.size <= 256
                && (1..=16).contains(&self.passes)
                && [
                    self.contrast,
                    self.brightness,
                    self.noise,
                    self.vibrancy,
                    self.vibrancy_darkness
                ]
                .iter()
                .all(|x| x.is_finite() && *x >= 0.0)
                && self.vibrancy_darkness <= 1.0,
            "invalid source blur recipe"
        );
        Ok(())
    }
    pub fn h264_sei(&self) -> Result<Vec<u8>> {
        self.validate()?;
        let mut payload = b"ViewflowBlur0001".to_vec();
        for word in [
            1,
            u32::from(self.enabled),
            self.size,
            self.passes,
            self.contrast.to_bits(),
            self.brightness.to_bits(),
            self.noise.to_bits(),
            self.vibrancy.to_bits(),
            self.vibrancy_darkness.to_bits(),
        ] {
            payload.extend(word.to_le_bytes());
        }
        let mut rbsp = vec![5, payload.len() as u8];
        rbsp.extend(payload);
        rbsp.push(0x80);
        let mut nal = vec![0, 0, 0, 1, 6];
        let mut zeros = 0;
        for byte in rbsp {
            if zeros >= 2 && byte <= 3 {
                nal.push(3);
                zeros = 0;
            }
            nal.push(byte);
            zeros = if byte == 0 { zeros + 1 } else { 0 };
        }
        Ok(nal)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[cfg(unix)]
    #[test]
    fn reads_effective_runtime_values_again_after_configuration_changes() {
        use std::io::{Read, Write};
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("hypr.sock");
        let server = std::os::unix::net::UnixListener::bind(&path).unwrap();
        let worker = std::thread::spawn(move || {
            for generation in 0..2 {
                for _ in 0..8 {
                    let (mut socket, _) = server.accept().unwrap();
                    let mut data = [0; 256];
                    let count = socket.read(&mut data).unwrap();
                    let query = std::str::from_utf8(&data[..count]).unwrap();
                    let key = query.rsplit(':').next().unwrap();
                    let value = match key {
                        "enabled" => serde_json::json!({"bool":generation==0}),
                        "size" => serde_json::json!({"int":if generation==0 {5}else{9}}),
                        "passes" => serde_json::json!({"int":if generation==0 {4}else{2}}),
                        "contrast" => serde_json::json!({"float":0.8916}),
                        "brightness" => serde_json::json!({"float":1.0}),
                        "noise" => serde_json::json!({"float":0.0117}),
                        "vibrancy" => serde_json::json!({"float":0.1696}),
                        "vibrancy_darkness" => serde_json::json!({"float":0.0}),
                        _ => panic!("unexpected query {query}"),
                    };
                    socket.write_all(value.to_string().as_bytes()).unwrap();
                }
            }
        });
        let ipc = HyprIpcClient::new(path);
        let first = BlurRecipe::read(&ipc).unwrap();
        let second = BlurRecipe::read(&ipc).unwrap();
        assert_eq!((first.enabled, first.size, first.passes), (true, 5, 4));
        assert_eq!((second.enabled, second.size, second.passes), (false, 9, 2));
        assert_ne!(first.h264_sei().unwrap(), second.h264_sei().unwrap());
        worker.join().unwrap();
    }
    #[test]
    fn sei_uses_registered_unregistered_payload_and_escaped_zeroes() {
        let recipe = BlurRecipe {
            enabled: true,
            size: 5,
            passes: 4,
            contrast: 0.8916,
            brightness: 1.,
            noise: 0.0117,
            vibrancy: 0.1696,
            vibrancy_darkness: 0.,
        };
        let sei = recipe.h264_sei().unwrap();
        assert_eq!(&sei[..7], &[0, 0, 0, 1, 6, 5, 52]);
        assert_eq!(&sei[7..23], b"ViewflowBlur0001");
        assert!(
            !sei[5..]
                .windows(3)
                .any(|x| x == [0, 0, 1] || x == [0, 0, 0])
        );
        assert_eq!(sei.last(), Some(&0x80));
        let mut invalid = recipe;
        invalid.noise = f32::NAN;
        assert!(invalid.h264_sei().is_err());
    }
}
