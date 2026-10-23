//! Control records for the local persistent decorated-window capture session.
//! Encoding/validation alone does not start a compositor stream.
use anyhow::{Result, bail};
use serde::Deserialize;
use serde_json::{Value, json};

pub struct StreamRequest<'a> {
    pub id: &'a str,
    pub window_address: &'a str,
    pub socket_path: &'a str,
    pub fps: u16,
}

/// Control record for the opt-in local DMA-BUF stream. This is deliberately
/// separate from the CPU `window` stream so a GPU request cannot be accepted
/// as a CPU capture response.
pub struct GpuStreamRequest<'a> {
    pub id: &'a str,
    pub window_address: &'a str,
    pub socket_path: &'a str,
    pub fps: u16,
}

impl GpuStreamRequest<'_> {
    #[allow(clippy::missing_errors_doc)]
    pub fn encode(&self) -> Result<Vec<u8>> {
        StreamRequest {
            id: self.id,
            window_address: self.window_address,
            socket_path: self.socket_path,
            fps: self.fps,
        }
        .encode()?;
        Ok(serde_json::to_vec(&json!({
            "id": self.id, "mode": "window-gpu", "windowAddress": self.window_address,
            "socketPath": self.socket_path, "fps": self.fps,
            "defaults": {"mode": "window", "windowBackground": "transparent",
                "windowBorder": "keep", "windowShadow": "keep"}
        }))?)
    }

    #[allow(clippy::missing_errors_doc)]
    pub fn validate_started(&self, bytes: &[u8]) -> Result<()> {
        if bytes.len() > 4096 {
            bail!("GPU stream response too large");
        }
        let response: GpuStartResponse = serde_json::from_slice(bytes)?;
        if !response.ok
            || response.version != 1
            || response.stream_id != self.id
            || response.socket_path != self.socket_path
            || response.mode != "window-gpu"
        {
            bail!("GPU stream start response identity or mode mismatch");
        }
        Ok(())
    }

    #[must_use]
    pub fn stop_record(&self) -> Value {
        json!({"streamId": self.id})
    }

    #[allow(clippy::missing_errors_doc)]
    pub fn validate_stopped(&self, bytes: &[u8]) -> Result<()> {
        StreamRequest {
            id: self.id,
            window_address: self.window_address,
            socket_path: self.socket_path,
            fps: self.fps,
        }
        .validate_stopped(bytes)
    }
}

impl StreamRequest<'_> {
    #[allow(clippy::missing_errors_doc)]
    pub fn encode(&self) -> Result<Vec<u8>> {
        if self.id.is_empty()
            || self.id.len() > 128
            || !self
                .id
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b == b'-')
            || !self.window_address.starts_with("0x")
            || self.window_address.len() <= 2
            || self.window_address.len() > 18
            || !self.window_address[2..]
                .bytes()
                .all(|b| b.is_ascii_hexdigit())
            || !self.socket_path.starts_with('/')
            || self.socket_path.len() >= 108
            || self.socket_path.as_bytes().contains(&0)
            || !(1..=1000).contains(&self.fps)
        {
            bail!("invalid window stream request");
        }
        Ok(serde_json::to_vec(&json!({
            "id": self.id, "mode": "window", "windowAddress": self.window_address,
            "socketPath": self.socket_path, "fps": self.fps,
            "defaults": {"mode": "window", "windowBackground": "transparent",
                "windowBorder": "keep", "windowShadow": "keep"}
        }))?)
    }

    #[allow(clippy::missing_errors_doc)]
    pub fn validate_started(&self, bytes: &[u8]) -> Result<()> {
        if bytes.len() > 4096 {
            bail!("stream response too large");
        }
        let response: StartResponse = serde_json::from_slice(bytes)?;
        if !response.ok
            || response.version != 1
            || response.stream_id != self.id
            || response.socket_path != self.socket_path
        {
            bail!("stream start response identity mismatch");
        }
        Ok(())
    }

    #[must_use]
    pub fn stop_record(&self) -> Value {
        json!({"streamId": self.id})
    }

    #[allow(clippy::missing_errors_doc)]
    pub fn validate_stopped(&self, bytes: &[u8]) -> Result<()> {
        if bytes.len() > 4096 {
            bail!("stream response too large");
        }
        let response: StopResponse = serde_json::from_slice(bytes)?;
        if !response.ok
            || response.version != 1
            || response.stream_id != self.id
            || !response.stopped
        {
            bail!("stream stop response identity mismatch");
        }
        Ok(())
    }
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
struct StartResponse {
    ok: bool,
    version: u16,
    stream_id: String,
    socket_path: String,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
struct GpuStartResponse {
    ok: bool,
    version: u16,
    stream_id: String,
    socket_path: String,
    mode: String,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
struct StopResponse {
    ok: bool,
    version: u16,
    stream_id: String,
    stopped: bool,
}

#[cfg(test)]
mod tests {
    use super::*;
    fn request() -> StreamRequest<'static> {
        StreamRequest {
            id: "test-1",
            window_address: "0x123",
            socket_path: "/tmp/private/frame.sock",
            fps: 120,
        }
    }
    #[test]
    fn preserves_decorations_and_allows_rates_above_60() {
        let value: Value = serde_json::from_slice(&request().encode().unwrap()).unwrap();
        assert_eq!(value["fps"], 120);
        assert_eq!(value["defaults"]["windowBorder"], "keep");
        assert_eq!(value["defaults"]["windowShadow"], "keep");
        assert_eq!(value["defaults"]["windowBackground"], "transparent");
    }
    #[test]
    fn rejects_wrong_duplicate_unknown_and_unbounded_response() {
        let r = request();
        let valid = br#"{"ok":true,"version":1,"streamId":"test-1","socketPath":"/tmp/private/frame.sock"}"#;
        r.validate_started(valid).unwrap();
        for bad in [
            br#"{"ok":true,"version":1,"streamId":"other","socketPath":"/tmp/private/frame.sock"}"#.as_slice(),
            br#"{"ok":true,"ok":true,"version":1,"streamId":"test-1","socketPath":"/tmp/private/frame.sock"}"#,
            br#"{"ok":true,"version":1,"streamId":"test-1","socketPath":"/tmp/private/frame.sock","extra":0}"#,
        ] { assert!(r.validate_started(bad).is_err()); }
        assert!(r.validate_started(&vec![b' '; 4097]).is_err());
        r.validate_stopped(br#"{"ok":true,"version":1,"streamId":"test-1","stopped":true}"#)
            .unwrap();
        assert!(
            r.validate_stopped(br#"{"ok":true,"version":1,"streamId":"test-1","stopped":false}"#)
                .is_err()
        );
    }

    #[test]
    fn gpu_request_requires_window_gpu_mode_echo() {
        let request = GpuStreamRequest {
            id: "gpu-1",
            window_address: "0x123",
            socket_path: "/tmp/private/gpu.sock",
            fps: 60,
        };
        let encoded: Value = serde_json::from_slice(&request.encode().unwrap()).unwrap();
        assert_eq!(encoded["mode"], "window-gpu");
        assert_eq!(encoded["defaults"]["mode"], "window");
        request.validate_started(br#"{"ok":true,"version":1,"streamId":"gpu-1","socketPath":"/tmp/private/gpu.sock","mode":"window-gpu"}"#).unwrap();
        assert!(request.validate_started(br#"{"ok":true,"version":1,"streamId":"gpu-1","socketPath":"/tmp/private/gpu.sock","mode":"window"}"#).is_err());
    }
}
