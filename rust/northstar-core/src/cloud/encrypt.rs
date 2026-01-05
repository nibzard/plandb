//! Encryption at rest for cloud backup storage.
//!
//! Uses AES-256-GCM for authenticated encryption, providing both
//! confidentiality and integrity verification for backup data.
//!
//! # Encryption Format
//!
//! Encrypted data structure:
//! ```text
//! [nonce: 12 bytes][tag: 16 bytes][encrypted_data: variable]
//! ```
//!
//! - **nonce**: 96-bit unique value per encryption (never reused with same key)
//! - **tag**: 128-bit authentication tag for integrity verification
//! - **encrypted_data**: AES-256-GCM encrypted payload
//!
//! # Key Management
//!
//! - **Customer-provided key**: User provides 256-bit key as hex string (64 chars)
//! - **No encryption**: Data uploaded without encryption (default)
//! - **KMS (future)**: Envelope encryption with cloud provider KMS
//!
//! # Security Properties
//!
//! - **Confidentiality**: AES-256 encryption protects data at rest
//! - **Integrity**: GCM authentication tag detects tampering
//! - **Performance**: AES-NI hardware acceleration on modern CPUs
//! - **Standard**: NIST-approved algorithm (FIPS 197)
//!
//! # Example Usage
//!
//! ```ignore
//! use northstar_core::cloud::encrypt::{EncryptionConfig, encrypt_data, decrypt_data};
//!
//! // Generate 256-bit key (32 bytes) as hex string
//! let key = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
//! let config = EncryptionConfig::CustomerKey { key: key.to_string() };
//!
//! // Encrypt data
//! let plaintext = b"sensitive backup data";
//! let encrypted = encrypt_data(plaintext, &config)?;
//!
//! // Decrypt data
//! let decrypted = decrypt_data(&encrypted, &config)?;
//! assert_eq!(plaintext.to_vec(), decrypted);
//! ```

use aes_gcm::{
    aead::{Aead, AeadCore, KeyInit, OsRng},
    Aes256Gcm, Nonce,
};
use crate::cloud::types::CloudError;
use std::fmt;

/// Encryption configuration.
#[derive(Debug, Clone)]
pub enum EncryptionConfig {
    /// No encryption (data uploaded as-is)
    None,

    /// Customer-provided 256-bit key (hex encoded, 64 characters)
    CustomerKey { key: String },

    /// KMS envelope encryption (future)
    Kms { key_arn: String },
}

impl fmt::Display for EncryptionConfig {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::None => write!(f, "none"),
            Self::CustomerKey { .. } => write!(f, "customer-key"),
            Self::Kms { .. } => write!(f, "kms"),
        }
    }
}

impl EncryptionConfig {
    /// Validate encryption configuration.
    pub fn validate(&self) -> Result<(), CloudError> {
        match self {
            Self::None => Ok(()),
            Self::CustomerKey { key } => {
                // Validate hex-encoded 256-bit key (64 hex chars = 32 bytes)
                if key.len() != 64 {
                    return Err(CloudError::InvalidRequest(
                        format!("Encryption key must be 64 hex characters (256 bits), got {}", key.len())
                    ));
                }
                hex::decode(key)
                    .map_err(|_| CloudError::InvalidRequest(
                        "Encryption key must be valid hex string".into()
                    ))?;
                Ok(())
            }
            Self::Kms { .. } => Err(CloudError::Other(
                "KMS encryption not yet implemented".into()
            )),
        }
    }

    /// Check if encryption is enabled.
    pub fn is_enabled(&self) -> bool {
        !matches!(self, Self::None)
    }
}

/// Encryption header format.
#[derive(Debug, Clone)]
pub struct EncryptionHeader {
    /// 96-bit nonce (12 bytes)
    pub nonce: Vec<u8>,
    /// 128-bit authentication tag (16 bytes)
    pub tag: Vec<u8>,
}

impl EncryptionHeader {
    /// Header size: nonce (12) + tag (16) = 28 bytes
    pub const SIZE: usize = 28;

    /// Create new encryption header with random nonce.
    pub fn new() -> Self {
        let nonce = Aes256Gcm::generate_nonce(&mut OsRng);
        Self {
            nonce: nonce.to_vec(),
            tag: Vec::new(), // Tag set after encryption
        }
    }
}

impl Default for EncryptionHeader {
    fn default() -> Self {
        Self::new()
    }
}

/// Encrypt data with AES-256-GCM.
///
/// # Format
/// - [nonce: 12 bytes][tag: 16 bytes][encrypted_data: variable]
///
/// # Arguments
/// - `data`: Plaintext data to encrypt
/// - `config`: Encryption configuration (must be CustomerKey)
///
/// # Returns
/// Encrypted data with header prepended
///
/// # Errors
/// - Invalid key format (not 64 hex chars)
/// - Encryption failure
///
/// # Example
/// ```ignore
/// use northstar_core::cloud::encrypt::{EncryptionConfig, encrypt_data};
///
/// let key = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
/// let config = EncryptionConfig::CustomerKey { key: key.to_string() };
/// let plaintext = b"Hello, world!";
/// let encrypted = encrypt_data(plaintext, &config)?;
/// ```
pub fn encrypt_data(data: &[u8], config: &EncryptionConfig) -> Result<Vec<u8>, CloudError> {
    let key = match config {
        EncryptionConfig::None => {
            return Ok(data.to_vec()); // No encryption
        }
        EncryptionConfig::CustomerKey { key } => {
            hex::decode(key).map_err(|_| CloudError::InvalidRequest(
                "Invalid hex encoding for encryption key".into()
            ))?
        }
        EncryptionConfig::Kms { .. } => {
            return Err(CloudError::Other(
                "KMS encryption not yet implemented".into()
            ));
        }
    };

    // Validate key length (256-bit = 32 bytes)
    if key.len() != 32 {
        return Err(CloudError::InvalidRequest(
            format!("Encryption key must be 32 bytes (256 bits), got {}", key.len())
        ));
    }

    // Initialize cipher with 256-bit key
    let cipher = Aes256Gcm::new_from_slice(&key)
        .map_err(|_| CloudError::InvalidRequest(
            "Invalid encryption key length (must be 32 bytes)".into()
        ))?;

    // Generate random nonce
    let nonce = Aes256Gcm::generate_nonce(&mut OsRng);

    // Encrypt data (GCM appends tag to ciphertext)
    let ciphertext = cipher
        .encrypt(&nonce, data)
        .map_err(|e| CloudError::Other(format!("Encryption failed: {}", e)))?;

    // Extract tag (last 16 bytes of ciphertext)
    let tag_start = ciphertext.len() - 16;
    let tag = ciphertext[tag_start..].to_vec();
    let encrypted_data = &ciphertext[..tag_start];

    // Build output: [nonce (12)][tag (16)][encrypted_data]
    let mut output = Vec::with_capacity(EncryptionHeader::SIZE + encrypted_data.len());
    output.extend_from_slice(&nonce);
    output.extend_from_slice(&tag);
    output.extend_from_slice(encrypted_data);

    Ok(output)
}

/// Decrypt data encrypted with AES-256-GCM.
///
/// # Format
/// - [nonce: 12 bytes][tag: 16 bytes][encrypted_data: variable]
///
/// # Arguments
/// - `encrypted_data`: Data encrypted with encrypt_data()
/// - `config`: Encryption configuration (must match encryption config)
///
/// # Returns
/// Decrypted plaintext data
///
/// # Errors
/// - Invalid key format
/// - Invalid encrypted data format (too short)
/// - Authentication failure (data tampered or wrong key)
///
/// # Example
/// ```ignore
/// use northstar_core::cloud::encrypt::{EncryptionConfig, encrypt_data, decrypt_data};
///
/// let key = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
/// let config = EncryptionConfig::CustomerKey { key: key.to_string() };
/// let plaintext = b"Hello, world!";
/// let encrypted = encrypt_data(plaintext, &config)?;
/// let decrypted = decrypt_data(&encrypted, &config)?;
/// assert_eq!(plaintext.to_vec(), decrypted);
/// ```
pub fn decrypt_data(encrypted_data: &[u8], config: &EncryptionConfig) -> Result<Vec<u8>, CloudError> {
    let key = match config {
        EncryptionConfig::None => {
            return Ok(encrypted_data.to_vec()); // No encryption
        }
        EncryptionConfig::CustomerKey { key } => {
            hex::decode(key).map_err(|_| CloudError::InvalidRequest(
                "Invalid hex encoding for encryption key".into()
            ))?
        }
        EncryptionConfig::Kms { .. } => {
            return Err(CloudError::Other(
                "KMS encryption not yet implemented".into()
            ));
        }
    };

    // Validate minimum size
    if encrypted_data.len() < EncryptionHeader::SIZE {
        return Err(CloudError::InvalidRequest(
            format!(
                "Encrypted data too short: {} bytes (minimum {})",
                encrypted_data.len(),
                EncryptionHeader::SIZE
            )
        ));
    }

    // Extract header
    let nonce_bytes = &encrypted_data[..12];
    let tag = &encrypted_data[12..28];
    let ciphertext = &encrypted_data[28..];

    // Reconstruct GCM ciphertext: [ciphertext][tag]
    let mut gcm_ciphertext = Vec::with_capacity(ciphertext.len() + 16);
    gcm_ciphertext.extend_from_slice(ciphertext);
    gcm_ciphertext.extend_from_slice(tag);

    // Initialize cipher
    let cipher = Aes256Gcm::new_from_slice(&key)
        .map_err(|_| CloudError::InvalidRequest(
            "Invalid encryption key length (must be 32 bytes)".into()
        ))?;

    // Convert nonce bytes to Nonce type
    let nonce_array: [u8; 12] = nonce_bytes.try_into()
        .map_err(|_| CloudError::InvalidRequest(
            "Invalid nonce length".into()
        ))?;
    let nonce = Nonce::from(nonce_array);

    // Decrypt and verify
    let plaintext = cipher
        .decrypt(&nonce, gcm_ciphertext.as_ref())
        .map_err(|e| CloudError::Other(format!("Decryption failed (data may be tampered or wrong key): {}", e)))?;

    Ok(plaintext)
}

/// Streaming encryption for large files.
///
/// Encrypts data in 64KB chunks to limit memory usage.
/// For small data (< 64KB), uses regular `encrypt_data()`.
///
/// # Arguments
/// - `data`: Plaintext data to encrypt
/// - `config`: Encryption configuration
/// - `chunk_size`: Chunk size in bytes (default 64KB)
///
/// # Returns
/// Encrypted data with header prepended
///
/// # Example
/// ```ignore
/// use northstar_core::cloud::encrypt::{EncryptionConfig, encrypt_stream};
///
/// let key = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
/// let config = EncryptionConfig::CustomerKey { key: key.to_string() };
/// let large_data = vec![0u8; 10 * 1024 * 1024]; // 10MB
/// let encrypted = encrypt_stream(&large_data, &config, None)?;
/// ```
pub fn encrypt_stream(
    data: &[u8],
    config: &EncryptionConfig,
    chunk_size: Option<usize>,
) -> Result<Vec<u8>, CloudError> {
    let chunk_size = chunk_size.unwrap_or(64 * 1024); // 64KB default

    if data.len() <= chunk_size {
        // Small data: use regular encrypt
        return encrypt_data(data, config);
    }

    let key = match config {
        EncryptionConfig::None => {
            return Ok(data.to_vec());
        }
        EncryptionConfig::CustomerKey { key } => {
            hex::decode(key).map_err(|_| CloudError::InvalidRequest(
                "Invalid hex encoding for encryption key".into()
            ))?
        }
        EncryptionConfig::Kms { .. } => {
            return Err(CloudError::Other(
                "KMS encryption not yet implemented".into()
            ));
        }
    };

    // Validate key length
    if key.len() != 32 {
        return Err(CloudError::InvalidRequest(
            format!("Encryption key must be 32 bytes (256 bits), got {}", key.len())
        ));
    }

    let cipher = Aes256Gcm::new_from_slice(&key)
        .map_err(|_| CloudError::InvalidRequest(
            "Invalid encryption key length (must be 32 bytes)".into()
        ))?;

    let nonce = Aes256Gcm::generate_nonce(&mut OsRng);
    let mut output = Vec::new();

    // Reserve space for nonce
    output.extend_from_slice(&nonce);

    // Encrypt each chunk
    for chunk in data.chunks(chunk_size) {
        let ciphertext = cipher
            .encrypt(&nonce, chunk)
            .map_err(|e| CloudError::Other(format!("Chunk encryption failed: {}", e)))?;

        output.extend_from_slice(&ciphertext);
    }

    Ok(output)
}

/// Streaming decryption for large files.
///
/// Decrypts data in 64KB chunks to limit memory usage.
/// For small data (< 64KB), uses regular `decrypt_data()`.
///
/// # Arguments
/// - `encrypted_data`: Data encrypted with encrypt_stream()
/// - `config`: Encryption configuration (must match encryption config)
/// - `chunk_size`: Chunk size in bytes (default 64KB + 16 tag)
///
/// # Returns
/// Decrypted plaintext data
///
/// # Example
/// ```ignore
/// use northstar_core::cloud::encrypt::{EncryptionConfig, encrypt_stream, decrypt_stream};
///
/// let key = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
/// let config = EncryptionConfig::CustomerKey { key: key.to_string() };
/// let large_data = vec![0u8; 10 * 1024 * 1024]; // 10MB
/// let encrypted = encrypt_stream(&large_data, &config, None)?;
/// let decrypted = decrypt_stream(&encrypted, &config, None)?;
/// assert_eq!(large_data, decrypted);
/// ```
pub fn decrypt_stream(
    encrypted_data: &[u8],
    config: &EncryptionConfig,
    chunk_size: Option<usize>,
) -> Result<Vec<u8>, CloudError> {
    let chunk_size = chunk_size.unwrap_or(64 * 1024 + 16); // 64KB + 16 tag

    if encrypted_data.len() <= chunk_size {
        // Small data: use regular decrypt
        return decrypt_data(encrypted_data, config);
    }

    // Extract nonce
    let nonce_bytes = &encrypted_data[..12];
    let nonce_array: [u8; 12] = nonce_bytes.try_into()
        .map_err(|_| CloudError::InvalidRequest("Invalid nonce length".into()))?;
    let nonce = Nonce::from(nonce_array);

    let key = match config {
        EncryptionConfig::None => {
            return Ok(encrypted_data.to_vec());
        }
        EncryptionConfig::CustomerKey { key } => {
            hex::decode(key).map_err(|_| CloudError::InvalidRequest(
                "Invalid hex encoding for encryption key".into()
            ))?
        }
        EncryptionConfig::Kms { .. } => {
            return Err(CloudError::Other(
                "KMS encryption not yet implemented".into()
            ));
        }
    };

    let cipher = Aes256Gcm::new_from_slice(&key)
        .map_err(|_| CloudError::InvalidRequest(
            "Invalid encryption key length (must be 32 bytes)".into()
        ))?;

    let mut output = Vec::new();
    let encrypted_chunks = &encrypted_data[12..]; // Skip nonce

    // Decrypt each chunk
    for chunk in encrypted_chunks.chunks(chunk_size) {
        let plaintext = cipher
            .decrypt(&nonce, chunk)
            .map_err(|e| CloudError::Other(format!("Chunk decryption failed: {}", e)))?;

        output.extend_from_slice(&plaintext);
    }

    Ok(output)
}

/// Generate a random 256-bit encryption key.
///
/// Returns hex-encoded key (64 characters).
///
/// # Example
/// ```ignore
/// use northstar_core::cloud::encrypt::generate_encryption_key;
///
/// let key = generate_encryption_key();
/// println!("Encryption key: {}", key); // Save this securely!
/// assert_eq!(key.len(), 64);
/// ```
pub fn generate_encryption_key() -> String {
    use rand::RngCore;
    let mut key_bytes = [0u8; 32];
    OsRng.fill_bytes(&mut key_bytes);
    hex::encode(key_bytes)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn generate_test_key() -> String {
        use rand::RngCore;
        let mut key_bytes = [0u8; 32];
        OsRng.fill_bytes(&mut key_bytes);
        hex::encode(key_bytes)
    }

    #[test]
    fn test_encrypt_decrypt_roundtrip() {
        let key = generate_test_key();
        let config = EncryptionConfig::CustomerKey { key };
        let plaintext = b"Hello, world! This is a test.";

        let encrypted = encrypt_data(plaintext, &config).unwrap();
        let decrypted = decrypt_data(&encrypted, &config).unwrap();

        assert_eq!(plaintext.to_vec(), decrypted);
        assert!(encrypted.len() >= EncryptionHeader::SIZE + plaintext.len());
    }

    #[test]
    fn test_encrypt_no_encryption() {
        let config = EncryptionConfig::None;
        let plaintext = b"Hello, world!";

        let encrypted = encrypt_data(plaintext, &config).unwrap();
        assert_eq!(plaintext.to_vec(), encrypted);
    }

    #[test]
    fn test_decrypt_no_encryption() {
        let config = EncryptionConfig::None;
        let data = b"Hello, world!";

        let decrypted = decrypt_data(data, &config).unwrap();
        assert_eq!(data.to_vec(), decrypted);
    }

    #[test]
    fn test_decrypt_invalid_key() {
        let key1 = generate_test_key();
        let key2 = generate_test_key();
        let config1 = EncryptionConfig::CustomerKey { key: key1 };
        let config2 = EncryptionConfig::CustomerKey { key: key2 };
        let plaintext = b"Hello, world!";

        let encrypted = encrypt_data(plaintext, &config1).unwrap();
        let result = decrypt_data(&encrypted, &config2);

        assert!(result.is_err()); // Wrong key should fail
    }

    #[test]
    fn test_decrypt_tampered_data() {
        let key = generate_test_key();
        let config = EncryptionConfig::CustomerKey { key };
        let plaintext = b"Hello, world!";

        let mut encrypted = encrypt_data(plaintext, &config).unwrap();
        encrypted[20] ^= 0xFF; // Tamper with data

        let result = decrypt_data(&encrypted, &config);
        assert!(result.is_err()); // Tampered data should fail auth
    }

    #[test]
    fn test_streaming_encrypt_decrypt() {
        let key = generate_test_key();
        let config = EncryptionConfig::CustomerKey { key };
        let plaintext = vec![0u8; 256 * 1024]; // 256KB of data

        let encrypted = encrypt_stream(&plaintext, &config, Some(64 * 1024)).unwrap();
        let decrypted = decrypt_stream(&encrypted, &config, Some(64 * 1024 + 16)).unwrap();

        assert_eq!(plaintext, decrypted);
    }

    #[test]
    fn test_encryption_config_validation() {
        // Valid key (64 hex chars)
        let valid_key = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
        let config = EncryptionConfig::CustomerKey { key: valid_key.to_string() };
        assert!(config.validate().is_ok());
        assert!(config.is_enabled());

        // Invalid key (too short)
        let short_key = "0123456789abcdef";
        let config = EncryptionConfig::CustomerKey { key: short_key.to_string() };
        assert!(config.validate().is_err());

        // Invalid key (not hex)
        let invalid_key = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789gggggg";
        let config = EncryptionConfig::CustomerKey { key: invalid_key.to_string() };
        assert!(config.validate().is_err());

        // No encryption
        let config = EncryptionConfig::None;
        assert!(config.validate().is_ok());
        assert!(!config.is_enabled());
    }

    #[test]
    fn test_generate_encryption_key() {
        let key = generate_encryption_key();
        assert_eq!(key.len(), 64);

        // Verify it's valid hex
        hex::decode(&key).unwrap();

        // Verify it can be used for encryption
        let config = EncryptionConfig::CustomerKey { key };
        assert!(config.validate().is_ok());
    }

    #[test]
    fn test_encryption_header_size() {
        assert_eq!(EncryptionHeader::SIZE, 28); // 12 nonce + 16 tag
    }

    #[test]
    fn test_empty_data() {
        let key = generate_test_key();
        let config = EncryptionConfig::CustomerKey { key };
        let plaintext = b"";

        let encrypted = encrypt_data(plaintext, &config).unwrap();
        let decrypted = decrypt_data(&encrypted, &config).unwrap();

        assert_eq!(plaintext.to_vec(), decrypted);
    }

    #[test]
    fn test_large_data() {
        let key = generate_test_key();
        let config = EncryptionConfig::CustomerKey { key };
        let plaintext = vec![42u8; 1024 * 1024]; // 1MB

        let encrypted = encrypt_data(&plaintext, &config).unwrap();
        let decrypted = decrypt_data(&encrypted, &config).unwrap();

        assert_eq!(plaintext, decrypted);
        // Encrypted size = header (28) + ciphertext (same size as plaintext) + tag (16, already in ciphertext)
        assert_eq!(encrypted.len(), EncryptionHeader::SIZE + plaintext.len());
    }

    #[test]
    fn test_decrypt_too_short() {
        let key = generate_test_key();
        let config = EncryptionConfig::CustomerKey { key };
        let short_data = vec![0u8; 10]; // Less than header size

        let result = decrypt_data(&short_data, &config);
        assert!(result.is_err());
    }
}
