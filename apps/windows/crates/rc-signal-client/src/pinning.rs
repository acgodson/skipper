//! TLS certificate pinning, mirroring `CertificatePinner.swift`.
//!
//! The server's certificate is self-signed and its SHA-256 (of the DER leaf) is
//! compiled into the client. CA validation is deliberately absent — there is no
//! CA, and pinning to the exact certificate is strictly stronger for a 1:1
//! deployment. `scripts` prove the pin is load-bearing the same way the Swift
//! side does: a wrong pin must fail the handshake.

use base64::engine::general_purpose::STANDARD as B64;
use base64::Engine;
use rustls::client::danger::{HandshakeSignatureValid, ServerCertVerified, ServerCertVerifier};
use rustls::{DigitallySignedStruct, Error as TlsError, SignatureScheme};
use rustls_pki_types::{CertificateDer, ServerName, UnixTime};
use sha2::{Digest, Sha256};

#[derive(Debug)]
pub struct PinnedCertVerifier {
    pin: [u8; 32],
}

impl PinnedCertVerifier {
    /// `pin_base64` is base64 of the SHA-256 of the server certificate's DER —
    /// the same string `RC_CERT_PIN` carries on the Mac side.
    pub fn new(pin_base64: &str) -> Result<Self, String> {
        let bytes = B64
            .decode(pin_base64.trim())
            .map_err(|e| format!("pin is not base64: {e}"))?;
        let pin: [u8; 32] = bytes
            .try_into()
            .map_err(|_| "pin must be 32 bytes (SHA-256)".to_string())?;
        Ok(Self { pin })
    }
}

impl ServerCertVerifier for PinnedCertVerifier {
    fn verify_server_cert(
        &self,
        end_entity: &CertificateDer<'_>,
        _intermediates: &[CertificateDer<'_>],
        _server_name: &ServerName<'_>,
        _ocsp_response: &[u8],
        _now: UnixTime,
    ) -> Result<ServerCertVerified, TlsError> {
        let got: [u8; 32] = Sha256::digest(end_entity.as_ref()).into();
        if got == self.pin {
            Ok(ServerCertVerified::assertion())
        } else {
            // The mismatch hash is safe and useful to log; the pin itself is
            // public knowledge (it ships in every client).
            Err(TlsError::General(format!(
                "certificate pin mismatch: presented sha256 {}",
                B64.encode(got)
            )))
        }
    }

    // Signature verification still runs — pinning replaces *chain* validation,
    // not proof of key possession. Delegating to the default provider keeps the
    // handshake honest: a MITM replaying the pinned cert without its key fails.
    fn verify_tls12_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, TlsError> {
        rustls::crypto::verify_tls12_signature(
            message,
            cert,
            dss,
            &rustls::crypto::ring::default_provider().signature_verification_algorithms,
        )
    }

    fn verify_tls13_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, TlsError> {
        rustls::crypto::verify_tls13_signature(
            message,
            cert,
            dss,
            &rustls::crypto::ring::default_provider().signature_verification_algorithms,
        )
    }

    fn supported_verify_schemes(&self) -> Vec<SignatureScheme> {
        rustls::crypto::ring::default_provider()
            .signature_verification_algorithms
            .supported_schemes()
    }
}

/// A rustls config that trusts exactly one certificate: the pinned one.
pub fn pinned_tls_config(pin_base64: &str) -> Result<rustls::ClientConfig, String> {
    let verifier = PinnedCertVerifier::new(pin_base64)?;
    Ok(rustls::ClientConfig::builder()
        .dangerous()
        .with_custom_certificate_verifier(std::sync::Arc::new(verifier))
        .with_no_client_auth())
}
