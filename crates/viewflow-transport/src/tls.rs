use std::{error::Error, io::Cursor, sync::Arc};

use quinn::{
    ClientConfig, ServerConfig,
    crypto::rustls::{QuicClientConfig, QuicServerConfig},
};
use rustls::{
    RootCertStore,
    pki_types::{CertificateDer, PrivateKeyDer, UnixTime},
    server::WebPkiClientVerifier,
};

use crate::{ALPN, ACTIVITY_ALPN};

type BoxError = Box<dyn Error + Send + Sync + 'static>;

#[derive(Debug)]
pub struct PeerIdentity {
    certificate_chain: Vec<CertificateDer<'static>>,
    private_key: PrivateKeyDer<'static>,
    roots: RootCertStore,
}

impl PeerIdentity {
    /// Parses a peer certificate, private key, and pairing trust roots from PEM.
    ///
    /// # Errors
    ///
    /// Returns an error for malformed PEM, a missing private key, or an invalid
    /// trust anchor.
    pub fn from_pem(
        certificate_chain_pem: &[u8],
        private_key_pem: &[u8],
        root_certificates_pem: &[u8],
    ) -> Result<Self, BoxError> {
        let certificate_chain = rustls_pemfile::certs(&mut Cursor::new(certificate_chain_pem))
            .collect::<Result<Vec<_>, _>>()?;
        let private_key = rustls_pemfile::private_key(&mut Cursor::new(private_key_pem))?
            .ok_or("PEM does not contain a private key")?;
        let mut roots = RootCertStore::empty();
        for root in rustls_pemfile::certs(&mut Cursor::new(root_certificates_pem)) {
            roots.add(root?)?;
        }
        if certificate_chain.is_empty() || roots.is_empty() {
            return Err("certificate chain and trust roots must not be empty".into());
        }
        Ok(Self {
            certificate_chain,
            private_key,
            roots,
        })
    }

    /// Checks that the private key belongs to the leaf certificate.
    ///
    /// # Errors
    ///
    /// Returns the rustls error for a mismatched or unusable key.
    pub fn check_key_matches_certificate(&self) -> Result<(), BoxError> {
        rustls::ServerConfig::builder()
            .with_no_client_auth()
            .with_single_cert(
                self.certificate_chain.clone(),
                self.private_key.clone_key(),
            )?;
        Ok(())
    }

    /// Verifies the leaf certificate against this identity's own pairing roots
    /// at `now`, as a remote peer would during the handshake.
    ///
    /// # Errors
    ///
    /// Returns the rustls verification error, such as an expired certificate
    /// or one issued by a different pairing authority.
    pub fn check_certificate_at(&self, now: UnixTime) -> Result<(), rustls::Error> {
        let verifier = WebPkiClientVerifier::builder(Arc::new(self.roots.clone()))
            .build()
            .map_err(|error| rustls::Error::General(error.to_string()))?;
        let (leaf, intermediates) = self
            .certificate_chain
            .split_first()
            .ok_or(rustls::Error::NoCertificatesPresented)?;
        verifier.verify_client_cert(leaf, intermediates, now)?;
        Ok(())
    }
}

/// Builds a QUIC server config that requires a paired client certificate.
///
/// # Errors
///
/// Returns an error when the certificate chain, key, or verifier is invalid.
pub fn build_server_config(identity: &PeerIdentity) -> Result<ServerConfig, BoxError> {
    let verifier = WebPkiClientVerifier::builder(Arc::new(identity.roots.clone())).build()?;
    let mut tls = rustls::ServerConfig::builder()
        .with_client_cert_verifier(verifier)
        .with_single_cert(
            identity.certificate_chain.clone(),
            identity.private_key.clone_key(),
        )?;
    tls.alpn_protocols = vec![ACTIVITY_ALPN.to_vec(), ALPN.to_vec()];
    let crypto = QuicServerConfig::try_from(tls)?;
    let mut config = ServerConfig::with_crypto(Arc::new(crypto));
    let mut transport = crate::media_transport_config();
    transport.max_concurrent_uni_streams(256_u32.into());
    transport.datagram_receive_buffer_size(Some(16 * 1024 * 1024));
    transport.datagram_send_buffer_size(16 * 1024 * 1024);
    config.transport_config(Arc::new(transport));
    Ok(config)
}

/// Builds a QUIC client config that presents its paired certificate.
///
/// # Errors
///
/// Returns an error when the certificate chain, key, or trust roots are invalid.
pub fn build_client_config(identity: &PeerIdentity) -> Result<ClientConfig, BoxError> {
    let mut tls = rustls::ClientConfig::builder()
        .with_root_certificates(identity.roots.clone())
        .with_client_auth_cert(
            identity.certificate_chain.clone(),
            identity.private_key.clone_key(),
        )?;
    tls.alpn_protocols = vec![ACTIVITY_ALPN.to_vec(), ALPN.to_vec()];
    let crypto = QuicClientConfig::try_from(tls)?;
    let mut config = ClientConfig::new(Arc::new(crypto));
    config.transport_config(Arc::new(crate::media_transport_config()));
    Ok(config)
}

#[cfg(test)]
mod activity_compatibility {
    use super::*;
    fn identity() -> PeerIdentity {
        PeerIdentity::from_pem(include_bytes!("../tests/fixtures/peer.pem"),
            include_bytes!("../tests/fixtures/peer.key"), include_bytes!("../tests/fixtures/ca.pem")).unwrap()
    }
    async fn negotiate(old_client: bool, old_server: bool) {
        let identity = identity();
        let server_config = if old_server {
            let verifier = WebPkiClientVerifier::builder(Arc::new(identity.roots.clone())).build().unwrap();
            let mut tls = rustls::ServerConfig::builder().with_client_cert_verifier(verifier)
                .with_single_cert(identity.certificate_chain.clone(), identity.private_key.clone_key()).unwrap();
            tls.alpn_protocols = vec![ALPN.to_vec()];
            ServerConfig::with_crypto(Arc::new(QuicServerConfig::try_from(tls).unwrap()))
        } else { build_server_config(&identity).unwrap() };
        let client_config = if old_client {
            let mut tls = rustls::ClientConfig::builder().with_root_certificates(identity.roots.clone())
                .with_client_auth_cert(identity.certificate_chain.clone(), identity.private_key.clone_key()).unwrap();
            tls.alpn_protocols = vec![ALPN.to_vec()];
            ClientConfig::new(Arc::new(QuicClientConfig::try_from(tls).unwrap()))
        } else { build_client_config(&identity).unwrap() };
        let server = quinn::Endpoint::server(server_config, "127.0.0.1:0".parse().unwrap()).unwrap();
        let mut client = quinn::Endpoint::client("127.0.0.1:0".parse().unwrap()).unwrap();
        client.set_default_client_config(client_config);
        let connect = client.connect(server.local_addr().unwrap(), "localhost").unwrap();
        let (client_connection, server_connection) = tokio::join!(connect, async {server.accept().await.unwrap().await});
        let client_connection = client_connection.unwrap();
        let server_connection = server_connection.unwrap();
        for connection in [&client_connection, &server_connection] {
            let handshake = connection.handshake_data().unwrap().downcast::<quinn::crypto::rustls::HandshakeData>().unwrap();
            assert_eq!(handshake.protocol.as_deref(), Some(if old_client || old_server {ALPN} else {ACTIVITY_ALPN}));
            assert!(connection.peer_identity().is_some());
        }
        client_connection.close(0u32.into(), b"compatibility test complete");
        server_connection.closed().await;
    }
    #[tokio::test]
    async fn activity_alpn_preserves_both_old_peer_directions() {
        negotiate(false, false).await;
        negotiate(true, false).await;
        negotiate(false, true).await;
    }
}

#[cfg(test)]
mod identity_checks {
    use super::*;
    use std::time::Duration;

    const CERT: &[u8] = include_bytes!("../tests/fixtures/peer.pem");
    const KEY: &[u8] = include_bytes!("../tests/fixtures/peer.key");
    const CA: &[u8] = include_bytes!("../tests/fixtures/ca.pem");
    // Inside the fixture validity window (2026-08-29 .. 2036-08-26).
    const VALID_AT: u64 = 1_800_000_000;

    #[test]
    fn fixture_identity_passes() {
        let identity = PeerIdentity::from_pem(CERT, KEY, CA).unwrap();
        identity.check_key_matches_certificate().unwrap();
        identity
            .check_certificate_at(UnixTime::since_unix_epoch(Duration::from_secs(VALID_AT)))
            .unwrap();
    }

    #[test]
    fn key_for_another_certificate_is_reported() {
        let identity = PeerIdentity::from_pem(CA, KEY, CA).unwrap();
        assert!(identity.check_key_matches_certificate().is_err());
    }

    #[test]
    fn expiry_and_clock_skew_are_reported() {
        let identity = PeerIdentity::from_pem(CERT, KEY, CA).unwrap();
        let at = |secs| UnixTime::since_unix_epoch(Duration::from_secs(secs));
        assert!(matches!(
            identity.check_certificate_at(at(2_200_000_000)),
            Err(rustls::Error::InvalidCertificate(
                rustls::CertificateError::Expired | rustls::CertificateError::ExpiredContext { .. }
            ))
        ));
        assert!(matches!(
            identity.check_certificate_at(at(1_000_000_000)),
            Err(rustls::Error::InvalidCertificate(
                rustls::CertificateError::NotValidYet
                    | rustls::CertificateError::NotValidYetContext { .. }
            ))
        ));
    }
}
