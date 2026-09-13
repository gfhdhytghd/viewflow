//! Source application icons and the receiver's private native icon cache.
use anyhow::Result;
use std::{
    collections::BTreeMap,
    path::{Path, PathBuf},
};
use viewflow_protocol::{ApplicationIcon, WindowId};

pub(crate) fn receiver_directory() -> PathBuf {
    std::env::temp_dir().join(format!("viewflow-icons-{}", std::process::id()))
}

pub(crate) struct ReceiverIcons {
    directory: PathBuf,
    installed: BTreeMap<WindowId, ApplicationIcon>,
}
impl ReceiverIcons {
    pub(crate) fn new() -> Self {
        Self {
            directory: receiver_directory(),
            installed: BTreeMap::new(),
        }
    }
    pub(crate) fn install(&mut self, icon: ApplicationIcon) -> Result<()> {
        let (width, height) = icon
            .dimensions()
            .map_err(|e| anyhow::anyhow!("invalid application icon: {e:?}"))?;
        if self.installed.get(&icon.window_id) == Some(&icon) {
            return Ok(());
        }
        anyhow::ensure!(
            self.installed.contains_key(&icon.window_id) || self.installed.len() < 4096,
            "application icon cache is full"
        );
        std::fs::create_dir_all(&self.directory)?;
        let stem = format!(
            "{}-{}",
            (icon.window_id.0 >> 64) as u64,
            icon.window_id.0 as u64
        );
        // A PNG-compressed ICO keeps alpha and all original application pixels.
        let mut bytes = vec![
            0,
            0,
            1,
            0,
            1,
            0,
            width as u8,
            height as u8,
            0,
            0,
            1,
            0,
            32,
            0,
        ];
        bytes.extend((icon.png.len() as u32).to_le_bytes());
        bytes.extend(22u32.to_le_bytes());
        bytes.extend(&icon.png);
        let mut hash = 0xcbf29ce484222325u64;
        for byte in icon.app_id.as_bytes() {
            hash = (hash ^ u64::from(*byte)).wrapping_mul(0x100000001b3);
        }
        std::fs::write(
            self.directory.join(format!("{stem}.appid")),
            format!("Viewflow.Remote.{hash:016x}"),
        )?;
        let temporary = self.directory.join(format!("{stem}.tmp"));
        let target = self.directory.join(format!("{stem}.ico"));
        std::fs::write(&temporary, bytes)?;
        if target.exists() {
            std::fs::remove_file(&target)?;
        }
        std::fs::rename(temporary, target)?;
        self.installed.insert(icon.window_id, icon);
        Ok(())
    }
}
impl Drop for ReceiverIcons {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.directory);
    }
}

#[cfg(unix)]
pub(crate) fn resolve(window_id: WindowId, app_id: &str) -> Option<ApplicationIcon> {
    use std::sync::{Mutex, OnceLock};
    static CACHE: OnceLock<Mutex<BTreeMap<String, Option<Vec<u8>>>>> = OnceLock::new();
    let cache = CACHE.get_or_init(|| Mutex::new(BTreeMap::new()));
    let mut cache = cache.lock().ok()?;
    let png = if let Some(found) = cache.get(app_id) {
        found.clone()
    } else {
        let found = resolve_png(app_id);
        if cache.len() < 256 {
            cache.insert(app_id.to_owned(), found.clone());
        }
        found
    }?;
    let icon = ApplicationIcon {
        window_id,
        app_id: app_id.into(),
        png,
    };
    icon.dimensions().ok()?;
    Some(icon)
}

#[cfg(unix)]
fn resolve_png(app_id: &str) -> Option<Vec<u8>> {
    if app_id.is_empty() || app_id.len() > 256 || app_id.contains(['/', '\\']) {
        return None;
    }
    let mut roots = Vec::new();
    if let Some(data) = std::env::var_os("XDG_DATA_HOME") {
        roots.push(PathBuf::from(data));
    } else if let Some(home) = std::env::var_os("HOME") {
        roots.push(PathBuf::from(home).join(".local/share"));
    }
    roots.extend(std::env::split_paths(
        &std::env::var_os("XDG_DATA_DIRS").unwrap_or_else(|| "/usr/local/share:/usr/share".into()),
    ));
    resolve_png_in_roots(app_id, &roots)
}

#[cfg(unix)]
fn resolve_png_in_roots(app_id: &str, roots: &[PathBuf]) -> Option<Vec<u8>> {
    let mut name = app_id.to_owned();
    'desktop: for root in roots {
        let entries = match std::fs::read_dir(root.join("applications")) {
            Ok(entries) => entries,
            Err(_) => continue,
        };
        for entry in entries.flatten() {
            let path = entry.path();
            if path.extension().and_then(|v| v.to_str()) != Some("desktop") {
                continue;
            }
            let text = match std::fs::read_to_string(&path) {
                Ok(text) => text,
                Err(_) => continue,
            };
            let mut section = false;
            let mut icon = None;
            let mut matches = path
                .file_stem()
                .is_some_and(|v| v.to_string_lossy().eq_ignore_ascii_case(app_id));
            for line in text.lines().map(str::trim) {
                if line.starts_with('[') {
                    section = line == "[Desktop Entry]";
                }
                if !section {
                    continue;
                }
                if let Some(value) = line.strip_prefix("Icon=") {
                    icon = Some(value.to_owned());
                }
                if let Some(value) = line.strip_prefix("StartupWMClass=") {
                    matches |= value.eq_ignore_ascii_case(app_id);
                }
            }
            if matches {
                if let Some(icon) = icon {
                    name = icon;
                    break 'desktop;
                }
            }
        }
    }
    let mut paths = Vec::new();
    if Path::new(&name).is_absolute() {
        paths.push(PathBuf::from(&name));
    } else if !name.contains(['/', '\\']) {
        for root in roots {
            for size in [64, 128, 256, 48, 32] {
                paths.push(root.join(format!("icons/hicolor/{size}x{size}/apps/{name}.png")));
            }
            paths.push(root.join(format!("pixmaps/{name}.png")));
            paths.push(root.join(format!("icons/hicolor/scalable/apps/{name}.svg")));
            paths.push(root.join(format!("pixmaps/{name}.svg")));
        }
    }
    for path in paths {
        let meta = match std::fs::metadata(&path) {
            Ok(meta) if meta.len() <= 1024 * 1024 => meta,
            _ => continue,
        };
        if !meta.is_file() {
            continue;
        }
        let png = if path.extension().is_some_and(|e| e == "svg") {
            match std::process::Command::new("rsvg-convert")
                .args(["-w", "64", "-h", "64"])
                .arg(&path)
                .output()
            {
                Ok(output) if output.status.success() => output.stdout,
                _ => continue,
            }
        } else {
            match std::fs::read(&path) {
                Ok(bytes) => bytes,
                Err(_) => continue,
            }
        };
        if (ApplicationIcon {
            window_id: viewflow_protocol::Id128(1),
            app_id: app_id.into(),
            png: png.clone(),
        })
        .dimensions()
        .is_ok()
        {
            return Some(png);
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;
    #[cfg(unix)]
    #[test]
    fn resolves_desktop_startup_class_to_installed_application_icon() {
        let root = tempfile::tempdir().unwrap();
        std::fs::create_dir_all(root.path().join("applications")).unwrap();
        std::fs::create_dir_all(root.path().join("icons/hicolor/32x32/apps")).unwrap();
        std::fs::write(root.path().join("applications/different-name.desktop"),
            "[Desktop Entry]\nStartupWMClass=custom-class\nIcon=actual-icon\n[Desktop Action Other]\nIcon=unrelated\n").unwrap();
        let png = include_bytes!("../tests/fixtures/application-icon.png");
        std::fs::write(
            root.path().join("icons/hicolor/32x32/apps/actual-icon.png"),
            png,
        )
        .unwrap();
        assert_eq!(
            resolve_png_in_roots("custom-class", &[root.path().into()]).unwrap(),
            png
        );
        assert!(resolve_png_in_roots("missing", &[root.path().into()]).is_none());
    }

    #[test]
    fn png_icon_becomes_a_lossless_ico_with_an_application_group() {
        let dir = tempfile::tempdir().unwrap();
        let mut cache = ReceiverIcons {
            directory: dir.path().join("icons"),
            installed: BTreeMap::new(),
        };
        let icon = ApplicationIcon {
            window_id: viewflow_protocol::Id128(9),
            app_id: "kitty".into(),
            png: include_bytes!("../tests/fixtures/application-icon.png").to_vec(),
        };
        cache.install(icon.clone()).unwrap();
        let ico = std::fs::read(cache.directory.join("0-9.ico")).unwrap();
        assert_eq!(&ico[..6], &[0, 0, 1, 0, 1, 0]);
        assert_eq!(&ico[22..], &icon.png);
        assert_eq!(
            std::fs::read_to_string(cache.directory.join("0-9.appid"))
                .unwrap()
                .len(),
            32
        );
        cache.install(icon).unwrap();
    }
}
