//! Connect independently streamed native windows to the desktop cursor lease.
//! A press followed by native window movement identifies a window drag; hover
//! and ordinary application clicks do not claim a window for native takeover.
use crate::atlas_cursor_handoff::{DragTransfer, SharedDragTransfer};
use crate::reverse_bridge::{NativeDrag, SharedNativeDrag};
use std::{collections::BTreeMap, path::PathBuf};
use viewflow_hyprland::{HyprIpcClient, resolve_socket_path};
use viewflow_protocol::Id128;

#[derive(Clone, Copy, Debug)]
struct Candidate {
    address: u64,
    pid: u32,
    surface: u64,
    proxy: Option<u64>,
    rect: [f64; 4],
    grab: (f64, f64),
}
impl Candidate {
    fn moved(&self, now: [f64; 4]) -> bool {
        (now[0] - self.rect[0])
            .abs()
            .max((now[1] - self.rect[1]).abs())
            > 0.5
            && (now[2] - self.rect[2]).abs() < 1.
            && (now[3] - self.rect[3]).abs() < 1.
    }
}
pub(crate) struct Observer {
    ipc: HyprIpcClient,
    bindings: PathBuf,
    pressed: bool,
    candidates: BTreeMap<u64, Candidate>,
    active: Option<u64>,
}
impl Observer {
    pub fn from_environment() -> Option<Self> {
        Some(Self {
            ipc: HyprIpcClient::new(resolve_socket_path().ok()?)
                .with_timeout(std::time::Duration::from_millis(100)),
            bindings: PathBuf::from(std::env::var_os("XDG_RUNTIME_DIR")?)
                .join("viewflow/macos-windows/bindings"),
            pressed: false,
            candidates: BTreeMap::new(),
            active: None,
        })
    }
    fn inventory(&self) -> anyhow::Result<Vec<Candidate>> {
        let clients: serde_json::Value = serde_json::from_str(&self.ipc.request("j/clients")?)?;
        let mut bindings = BTreeMap::new();
        if let Ok(entries) = std::fs::read_dir(&self.bindings) {
            for entry in entries.flatten() {
                let Ok(data) = std::fs::read(entry.path()) else {
                    continue;
                };
                let Ok(value) = serde_json::from_slice::<serde_json::Value>(&data) else {
                    continue;
                };
                let Some(producer) = value["producer_pid"].as_u64() else {
                    continue;
                };
                if !std::fs::read_link(format!("/proc/{producer}/exe"))
                    .ok()
                    .is_some_and(|p| p.file_name().is_some_and(|s| s == "vf-hyprland-windows"))
                {
                    continue;
                }
                if let (Some(address), Some(pid), Some(surface)) = (
                    value["window"].as_u64(),
                    value["pid"].as_u64(),
                    value["surface"].as_u64(),
                ) {
                    bindings.insert((address, pid), surface);
                }
            }
        }
        let mut result = Vec::new();
        for w in clients.as_array().into_iter().flatten() {
            if w["mapped"] != true || w["floating"] != true {
                continue;
            }
            let Some(address) = w["address"]
                .as_str()
                .and_then(|s| u64::from_str_radix(s.trim_start_matches("0x"), 16).ok())
            else {
                continue;
            };
            let Some(pid) = w["pid"].as_u64().and_then(|n| u32::try_from(n).ok()) else {
                continue;
            };
            let proxy = w["class"]
                .as_str()
                .and_then(|s| s.strip_prefix("ViewflowReverse-Mac-"))
                .and_then(|s| s.parse().ok());
            let surface = bindings
                .get(&(address, u64::from(pid)))
                .copied()
                .unwrap_or(0);
            if proxy.is_none() && surface == 0 {
                continue;
            }
            let rect = [
                w["at"][0].as_f64(),
                w["at"][1].as_f64(),
                w["size"][0].as_f64(),
                w["size"][1].as_f64(),
            ];
            if rect.iter().any(Option::is_none) {
                continue;
            }
            result.push(Candidate {
                address,
                pid,
                surface,
                proxy,
                rect: rect.map(Option::unwrap),
                grab: (0., 0.),
            });
        }
        Ok(result)
    }
    pub async fn observe(
        &mut self,
        position: (f64, f64),
        pressed: bool,
        transfer: &SharedDragTransfer,
        reverse: &SharedNativeDrag,
    ) {
        if !pressed {
            if self.pressed {
                self.candidates.clear();
                self.active = None;
                *transfer.lock().await = None;
                *reverse.lock().await = None;
            }
            self.pressed = false;
            return;
        }
        let Ok(current) = self.inventory() else {
            return;
        };
        if !self.pressed {
            self.pressed = true;
            self.active = None;
            self.candidates.clear();
            for mut candidate in current {
                let [x, y, w, h] = candidate.rect;
                if position.0 >= x && position.0 < x + w && position.1 >= y && position.1 < y + h {
                    candidate.grab = (position.0 - x, position.1 - y);
                    self.candidates.insert(candidate.address, candidate);
                }
            }
            return;
        }
        if self.active.is_some() {
            return;
        }
        for now in current {
            let Some(start) = self
                .candidates
                .get(&now.address)
                .filter(|start| start.pid == now.pid && start.moved(now.rect))
            else {
                continue;
            };
            self.active = Some(now.address);
            if let Some(id) = now.proxy {
                let drag = NativeDrag {
                    id,
                    pid: now.pid,
                    address: now.address,
                    grab_offset: Some(start.grab),
                    handed_off: false,
                };
                *reverse.lock().await = Some(drag);
                *reverse.latest_start.lock().await = Some((tokio::time::Instant::now(), drag));
                reverse.changed.notify_one();
            } else {
                *transfer.lock().await = Some(DragTransfer {
                    window: Id128(1),
                    target: viewflow_hyprland::capture_wire::DragTarget {
                        pid: now.pid,
                        address: now.address,
                        surface: now.surface,
                        reverse_id: 1,
                        grab_offset: Some(start.grab),
                    },
                    handed_off: false,
                    resizing: false,
                    move_confirmed: true,
                });
            }
            eprintln!(
                "cursor native window drag bound pid={} address=0x{:x} proxy={:?} grab={:?}",
                now.pid, now.address, now.proxy, start.grab
            );
            break;
        }
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn only_position_change_preserving_extent_claims_a_drag() {
        let candidate = Candidate {
            address: 1,
            pid: 2,
            surface: 3,
            proxy: None,
            rect: [100., 200., 800., 600.],
            grab: (40., 20.),
        };
        assert!(!candidate.moved(candidate.rect));
        assert!(candidate.moved([99., 200., 800., 600.]));
        assert!(!candidate.moved([99., 200., 820., 600.]));
    }
}
