//! Read-only setup diagnostics for `viewflowd doctor`.
//!
//! Each check explains the usual cause and the fix in plain words, so a
//! misconfigured pairing does not surface only as an opaque handshake error.
//! Nothing here posts input, changes focus, or writes to the identity files.

use std::{
    collections::BTreeMap,
    io::ErrorKind,
    net::{SocketAddr, UdpSocket},
    path::Path,
    time::{Duration, SystemTime},
};

use anyhow::{Context, Result, anyhow};
use rustls::{CertificateError, pki_types::UnixTime};
use viewflow_transport::{PeerIdentity, build_client_config};

use crate::IdentityPaths;

const DEFAULT_TIMEOUT: Duration = Duration::from_secs(3);
// Warn early enough to re-pair before the certificate stops working.
const EXPIRY_WARNING: Duration = Duration::from_secs(14 * 24 * 60 * 60);

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct DoctorConfig {
    pub identity: Option<IdentityPaths>,
    pub bind: Option<SocketAddr>,
    pub peer: Option<SocketAddr>,
    pub server_name: Option<String>,
    pub timeout: Duration,
    pub json: bool,
}

impl DoctorConfig {
    pub(crate) fn from_options(options: &BTreeMap<String, String>) -> Result<Self> {
        super::reject_unknown(
            options,
            &["cert", "key", "ca", "bind", "peer", "server-name", "timeout-ms", "format"],
        )?;
        let identity = match (options.get("cert"), options.get("key"), options.get("ca")) {
            (None, None, None) => None,
            (Some(_), Some(_), Some(_)) => Some(IdentityPaths {
                certificate: super::required_path(options, "cert")?,
                private_key: super::required_path(options, "key")?,
                certificate_authority: super::required_path(options, "ca")?,
            }),
            _ => anyhow::bail!("--cert, --key and --ca must be given together"),
        };
        let bind = options.contains_key("bind").then(|| super::required_socket(options, "bind")).transpose()?;
        let peer = options.contains_key("peer").then(|| super::required_socket(options, "peer")).transpose()?;
        let server_name = options.get("server-name").cloned();
        if peer.is_some() && (identity.is_none() || server_name.is_none()) {
            anyhow::bail!("--peer also needs --server-name, --cert, --key and --ca");
        }
        let timeout = match options.get("timeout-ms") {
            Some(value) => Duration::from_millis(
                value
                    .parse::<u64>()
                    .ok()
                    .filter(|ms| (1..=60_000).contains(ms))
                    .ok_or_else(|| anyhow!("--timeout-ms must be 1..=60000"))?,
            ),
            None => DEFAULT_TIMEOUT,
        };
        let json = match options.get("format").map(String::as_str) {
            None | Some("text") => false,
            Some("json") => true,
            Some(other) => anyhow::bail!("--format must be text or json, got {other:?}"),
        };
        Ok(Self { identity, bind, peer, server_name, timeout, json })
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, serde::Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Level {
    Ok,
    Warn,
    Fail,
}

#[derive(Clone, Debug, serde::Serialize)]
pub struct Finding {
    pub check: &'static str,
    pub level: Level,
    pub detail: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub hint: Option<String>,
}

impl Finding {
    fn ok(check: &'static str, detail: impl Into<String>) -> Self {
        Self { check, level: Level::Ok, detail: detail.into(), hint: None }
    }
    fn warn(check: &'static str, detail: impl Into<String>, hint: impl Into<String>) -> Self {
        Self { check, level: Level::Warn, detail: detail.into(), hint: Some(hint.into()) }
    }
    fn fail(check: &'static str, detail: impl Into<String>, hint: impl Into<String>) -> Self {
        Self { check, level: Level::Fail, detail: detail.into(), hint: Some(hint.into()) }
    }
}

/// Runs every applicable check, prints the report, and returns `Err` when any
/// check failed so scripts and service managers see a non-zero exit.
///
/// # Errors
///
/// Returns an error summarizing failed checks.
pub async fn run(config: &DoctorConfig) -> Result<()> {
    let findings = collect(config).await;
    if config.json {
        println!("{}", serde_json::to_string_pretty(&findings)?);
    } else {
        for finding in &findings {
            let tag = match finding.level {
                Level::Ok => "[ OK ]",
                Level::Warn => "[WARN]",
                Level::Fail => "[FAIL]",
            };
            println!("{tag} {}: {}", finding.check, finding.detail);
            if let Some(hint) = &finding.hint {
                println!("       -> {hint}");
            }
        }
    }
    let failed = findings.iter().filter(|f| f.level == Level::Fail).count();
    if failed > 0 {
        anyhow::bail!("{failed} check(s) failed");
    }
    Ok(())
}

pub async fn collect(config: &DoctorConfig) -> Vec<Finding> {
    let mut findings = Vec::new();
    let identity = config
        .identity
        .as_ref()
        .and_then(|paths| check_identity(paths, SystemTime::now(), &mut findings));
    if let Some(bind) = config.bind {
        findings.push(check_bind(bind));
    }
    if let (Some(peer), Some(server_name), Some(identity)) =
        (config.peer, config.server_name.as_deref(), identity.as_ref())
    {
        findings.push(check_peer(identity, peer, server_name, config.timeout).await);
    } else if config.peer.is_some() {
        findings.push(Finding::fail(
            "peer",
            "skipped because the local identity is unusable",
            "fix the identity findings above first",
        ));
    }
    findings.extend(check_platform());
    if findings.is_empty() {
        findings.push(Finding::warn(
            "doctor",
            "nothing to check",
            "pass --cert/--key/--ca, --bind, or --peer with --server-name",
        ));
    }
    findings
}

fn check_identity(
    paths: &IdentityPaths,
    now: SystemTime,
    findings: &mut Vec<Finding>,
) -> Option<PeerIdentity> {
    let mut contents = Vec::with_capacity(3);
    for (label, path) in [
        ("certificate", &paths.certificate),
        ("private key", &paths.private_key),
        ("pairing CA", &paths.certificate_authority),
    ] {
        match std::fs::read(path) {
            Ok(bytes) => contents.push(bytes),
            Err(error) => {
                findings.push(Finding::fail(
                    "identity",
                    format!("cannot read {label} {}: {error}", path.display()),
                    read_hint(error.kind()),
                ));
                return None;
            }
        }
    }
    findings.extend(check_key_permissions(&paths.private_key));
    let identity = match PeerIdentity::from_pem(&contents[0], &contents[1], &contents[2]) {
        Ok(identity) => identity,
        Err(error) => {
            findings.push(Finding::fail(
                "identity",
                format!("PEM files are not a usable identity: {error}"),
                "check that --cert, --key and --ca point at the files written by pairing and are not swapped",
            ));
            return None;
        }
    };
    if let Err(error) = identity.check_key_matches_certificate() {
        findings.push(Finding::fail(
            "identity",
            format!("private key does not belong to the certificate: {error}"),
            "the key and certificate come from different pairings; re-pair this device or use the matching pair",
        ));
        return None;
    }
    let at = |time: SystemTime| {
        UnixTime::since_unix_epoch(time.duration_since(SystemTime::UNIX_EPOCH).unwrap_or_default())
    };
    match identity.check_certificate_at(at(now)) {
        Ok(()) => {
            if identity.check_certificate_at(at(now + EXPIRY_WARNING)).is_err() {
                findings.push(Finding::warn(
                    "identity",
                    "certificate expires within 14 days",
                    "re-pair the devices soon to issue a new certificate",
                ));
            } else {
                findings.push(Finding::ok("identity", "certificate, key and pairing CA agree"));
            }
            Some(identity)
        }
        Err(error) => {
            findings.push(Finding::fail(
                "identity",
                format!("certificate is not accepted by its own pairing CA: {error}"),
                certificate_hint(&error),
            ));
            None
        }
    }
}

fn read_hint(kind: ErrorKind) -> &'static str {
    match kind {
        ErrorKind::NotFound => "the path is wrong or pairing has not been completed on this device",
        ErrorKind::PermissionDenied => {
            "the service user cannot read this file; run as the user that owns the pairing files"
        }
        _ => "check that the path is a readable regular file",
    }
}

fn certificate_hint(error: &rustls::Error) -> &'static str {
    match error {
        rustls::Error::InvalidCertificate(
            CertificateError::Expired | CertificateError::ExpiredContext { .. },
        ) => "the certificate has expired, or this device's clock is ahead; check the clock, then re-pair",
        rustls::Error::InvalidCertificate(
            CertificateError::NotValidYet | CertificateError::NotValidYetContext { .. },
        ) => "this device's clock is behind the certificate issue time; enable time sync",
        rustls::Error::InvalidCertificate(CertificateError::UnknownIssuer) => {
            "--ca is from a different pairing than --cert; use the CA written together with this certificate"
        }
        _ => "re-pair the devices to issue a fresh identity",
    }
}

#[cfg(unix)]
fn check_key_permissions(path: &Path) -> Option<Finding> {
    use std::os::unix::fs::PermissionsExt;
    let mode = std::fs::metadata(path).ok()?.permissions().mode();
    (mode & 0o077 != 0).then(|| {
        Finding::warn(
            "identity",
            format!("private key {} is readable by other users (mode {:o})", path.display(), mode & 0o777),
            format!("run: chmod 600 {}", path.display()),
        )
    })
}

#[cfg(not(unix))]
fn check_key_permissions(_: &Path) -> Option<Finding> {
    None
}

fn check_bind(bind: SocketAddr) -> Finding {
    match UdpSocket::bind(bind) {
        Ok(_) => Finding::ok("bind", format!("UDP {bind} is free")),
        Err(error) if error.kind() == ErrorKind::AddrInUse => Finding::fail(
            "bind",
            format!("UDP {bind} is already in use"),
            "another viewflowd instance is probably running; stop it or choose another --bind port",
        ),
        Err(error) if error.kind() == ErrorKind::AddrNotAvailable => Finding::fail(
            "bind",
            format!("{} is not an address of this machine", bind.ip()),
            "use 0.0.0.0 (all interfaces) or an IP shown by `ip addr` / `ipconfig`",
        ),
        Err(error) if error.kind() == ErrorKind::PermissionDenied => Finding::fail(
            "bind",
            format!("not allowed to bind UDP {bind}"),
            "ports below 1024 need privileges; use a higher port",
        ),
        Err(error) => Finding::fail("bind", format!("cannot bind UDP {bind}: {error}"), "check --bind"),
    }
}

async fn check_peer(
    identity: &PeerIdentity,
    peer: SocketAddr,
    server_name: &str,
    timeout: Duration,
) -> Finding {
    match handshake(identity, peer, server_name, timeout).await {
        Ok(()) => Finding::ok("peer", format!("authenticated QUIC handshake with {peer} succeeded")),
        Err(error) => {
            let text = format!("{error:#}");
            Finding::fail("peer", format!("handshake with {peer} failed: {text}"), peer_hint(&text, server_name))
        }
    }
}

async fn handshake(
    identity: &PeerIdentity,
    peer: SocketAddr,
    server_name: &str,
    timeout: Duration,
) -> Result<()> {
    let local: SocketAddr = if peer.is_ipv4() { "0.0.0.0:0" } else { "[::]:0" }
        .parse()
        .context("local wildcard address")?;
    let mut endpoint = quinn::Endpoint::client(local).context("open local UDP socket")?;
    endpoint.set_default_client_config(
        build_client_config(identity).map_err(|error| anyhow!("client TLS config: {error}"))?,
    );
    let connecting = endpoint.connect(peer, server_name).context("start handshake")?;
    match tokio::time::timeout(timeout, connecting).await {
        Ok(Ok(connection)) => {
            // Tell the peer promptly so it does not hold a half-open session.
            connection.close(0u32.into(), b"doctor");
            let _ = tokio::time::timeout(timeout, endpoint.wait_idle()).await;
            Ok(())
        }
        Ok(Err(error)) => Err(anyhow!(error)),
        Err(_) => Err(anyhow!("no answer within {} ms", timeout.as_millis())),
    }
}

fn peer_hint(error: &str, server_name: &str) -> String {
    let lower = error.to_ascii_lowercase();
    if lower.contains("no answer within") || lower.contains("timed out") {
        "the peer did not respond: check that viewflowd serve is running there, the IP/port are right, \
         and the firewall allows UDP to that port"
            .into()
    } else if lower.contains("notvalidforname") || lower.contains("not valid for name") {
        format!("--server-name {server_name:?} does not match the name in the peer certificate; use the name shown during pairing")
    } else if lower.contains("unknownissuer") || lower.contains("unknown ca") {
        "the two devices were paired with different authorities; pair them again".into()
    } else if lower.contains("expired") || lower.contains("notvalidyet") {
        "a certificate is outside its validity window; check both clocks, then re-pair if needed".into()
    } else if lower.contains("certificate required") || lower.contains("bad certificate") {
        "the peer rejected this device's certificate; pair the devices again".into()
    } else if lower.contains("no application protocol") || lower.contains("alpn") {
        "the peer runs an incompatible Viewflow version; update both devices to the same release".into()
    } else if lower.contains("refused") || lower.contains("unreachable") {
        "the network reported the peer unreachable; check the address and that both devices share a network".into()
    } else {
        "check the peer address and that both devices run the same Viewflow release".into()
    }
}

#[cfg(target_os = "macos")]
fn check_platform() -> Vec<Finding> {
    if viewflow_platform::macos_input::MacOsInputBackend::is_authorized() {
        vec![Finding::ok("input permission", "Accessibility access is granted")]
    } else {
        vec![Finding::warn(
            "input permission",
            "Accessibility access is not granted, so remote input cannot be posted",
            "System Settings > Privacy & Security > Accessibility: enable Viewflow, then restart it",
        )]
    }
}

#[cfg(target_os = "linux")]
fn check_platform() -> Vec<Finding> {
    let wayland = std::env::var_os("WAYLAND_DISPLAY").is_some();
    let x11 = std::env::var_os("DISPLAY").is_some();
    if wayland || x11 {
        vec![Finding::ok("session", if wayland { "Wayland session detected" } else { "X11 session detected" })]
    } else {
        vec![Finding::warn(
            "session",
            "no graphical session in this environment",
            "window and input features need the user session; run from it or import its environment into the service",
        )]
    }
}

#[cfg(not(any(target_os = "macos", target_os = "linux")))]
fn check_platform() -> Vec<Finding> {
    Vec::new()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fixture(name: &str) -> std::path::PathBuf {
        Path::new(env!("CARGO_MANIFEST_DIR")).join("../viewflow-transport/tests/fixtures").join(name)
    }

    fn fixture_paths() -> IdentityPaths {
        IdentityPaths {
            certificate: fixture("peer.pem"),
            private_key: fixture("peer.key"),
            certificate_authority: fixture("ca.pem"),
        }
    }

    fn at(secs: u64) -> SystemTime {
        SystemTime::UNIX_EPOCH + Duration::from_secs(secs)
    }

    #[test]
    fn options_require_complete_groups() {
        let options = |pairs: &[(&str, &str)]| {
            pairs.iter().map(|(k, v)| ((*k).to_owned(), (*v).to_owned())).collect::<BTreeMap<_, _>>()
        };
        assert!(DoctorConfig::from_options(&options(&[("cert", "a")])).is_err());
        assert!(DoctorConfig::from_options(&options(&[("peer", "127.0.0.1:1")])).is_err());
        assert!(DoctorConfig::from_options(&options(&[("format", "yaml")])).is_err());
        let config = DoctorConfig::from_options(&options(&[("bind", "127.0.0.1:0"), ("format", "json")])).unwrap();
        assert!(config.json && config.bind.is_some() && config.identity.is_none());
    }

    #[test]
    fn valid_identity_is_ok_and_near_expiry_warns() {
        let mut findings = Vec::new();
        assert!(check_identity(&fixture_paths(), at(1_800_000_000), &mut findings).is_some());
        assert!(findings.iter().any(|f| f.level == Level::Ok && f.check == "identity"));
        let mut findings = Vec::new();
        // 2036-08-20, six days before the fixture certificate expires.
        assert!(check_identity(&fixture_paths(), at(2_102_976_000), &mut findings).is_some());
        assert!(findings.iter().any(|f| f.level == Level::Warn && f.detail.contains("expires")));
    }

    #[test]
    fn clock_behind_is_explained() {
        let mut findings = Vec::new();
        assert!(check_identity(&fixture_paths(), at(1_000_000_000), &mut findings).is_none());
        let failure = findings.iter().find(|f| f.level == Level::Fail).unwrap();
        assert!(failure.hint.as_deref().unwrap().contains("clock"));
    }

    #[test]
    fn swapped_or_missing_files_are_explained() {
        let mut swapped = fixture_paths();
        swapped.certificate = fixture("ca.pem");
        let mut findings = Vec::new();
        assert!(check_identity(&swapped, at(1_800_000_000), &mut findings).is_none());
        assert!(findings.iter().any(|f| f.level == Level::Fail && f.detail.contains("does not belong")));

        let mut missing = fixture_paths();
        missing.private_key = fixture("absent.key");
        let mut findings = Vec::new();
        assert!(check_identity(&missing, at(1_800_000_000), &mut findings).is_none());
        assert!(findings[0].hint.as_deref().unwrap().contains("pairing"));
    }

    #[test]
    fn busy_port_is_explained() {
        let held = UdpSocket::bind("127.0.0.1:0").unwrap();
        let finding = check_bind(held.local_addr().unwrap());
        assert_eq!(finding.level, Level::Fail);
        assert!(finding.hint.unwrap().contains("another viewflowd"));
    }

    #[tokio::test]
    async fn silent_peer_reports_firewall_hint_and_live_peer_passes() {
        let paths = fixture_paths();
        let mut findings = Vec::new();
        let identity = check_identity(&paths, SystemTime::now(), &mut findings).unwrap();
        // A bound socket that never answers QUIC.
        let silent = UdpSocket::bind("127.0.0.1:0").unwrap();
        let finding =
            check_peer(&identity, silent.local_addr().unwrap(), "localhost", Duration::from_millis(200)).await;
        assert_eq!(finding.level, Level::Fail);
        assert!(finding.hint.unwrap().contains("firewall"));

        let server_config = viewflow_transport::build_server_config(&identity).unwrap();
        let server = quinn::Endpoint::server(server_config, "127.0.0.1:0".parse().unwrap()).unwrap();
        let address = server.local_addr().unwrap();
        let accept = tokio::spawn(async move {
            while let Some(incoming) = server.accept().await {
                let _ = incoming.await;
            }
        });
        let finding = check_peer(&identity, address, "localhost", Duration::from_secs(2)).await;
        assert_eq!(finding.level, Level::Ok, "{finding:?}");
        let finding = check_peer(&identity, address, "wrong.example", Duration::from_secs(2)).await;
        assert!(finding.hint.as_deref().unwrap().contains("--server-name"), "{finding:?}");
        accept.abort();
    }
}
