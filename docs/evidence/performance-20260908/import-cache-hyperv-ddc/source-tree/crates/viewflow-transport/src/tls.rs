use std::{error::Error, io::Cursor, sync::Arc};

use quinn::{
    ClientConfig, ServerConfig,
    crypto::rustls::{QuicClientConfig, QuicServerConfig},
};
use rustls::{
    RootCertStore,
    pki_types::{CertificateDer, PrivateKeyDer},
    server::WebPkiClientVerifier,
};

use crate::ALPN;

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
    tls.alpn_protocols = vec![ALPN.to_vec()];
    let crypto = QuicServerConfig::try_from(tls)?;
    let mut config = ServerConfig::with_crypto(Arc::new(crypto));
    let transport = Arc::get_mut(&mut config.transport)
        .ok_or("new server transport config must be exclusively owned")?;
    transport.max_concurrent_uni_streams(256_u32.into());
    transport.datagram_receive_buffer_size(Some(16 * 1024 * 1024));
    transport.datagram_send_buffer_size(16 * 1024 * 1024);
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
    tls.alpn_protocols = vec![ALPN.to_vec()];
    let crypto = QuicClientConfig::try_from(tls)?;
    Ok(ClientConfig::new(Arc::new(crypto)))
}
