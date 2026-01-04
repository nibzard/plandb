//! Checksum module for CRC32C integrity verification.
//!
//! Provides CRC32C (Castagnoli polynomial) checksums for page validation
//! and WAL record integrity.

pub use crc32c::{crc32c, crc32c_append};
pub mod crc32c_mod {
    pub use crc32c::*;
}

/// CRC32C hasher for incremental checksum calculation
pub struct Crc32cHasher {
    state: u32,
}

impl Crc32cHasher {
    /// Create a new hasher
    pub fn new() -> Self {
        Crc32cHasher { state: 0 }
    }

    /// Update the hasher with new data
    pub fn update(&mut self, data: &[u8]) {
        self.state = crc32c_append(self.state, data);
    }

    /// Finalize and return the checksum
    pub fn finalize(self) -> u32 {
        self.state
    }

    /// Reset the hasher to initial state
    pub fn reset(&mut self) {
        self.state = 0;
    }
}

impl Default for Crc32cHasher {
    fn default() -> Self {
        Self::new()
    }
}

/// Compute CRC32C checksum of a byte slice.
///
/// Uses hardware-accelerated CRC32C instructions when available.
#[inline]
pub fn checksum(data: &[u8]) -> u32 {
    crc32c(data)
}

/// Compute CRC32C checksum of a byte slice with a starting value.
#[inline]
pub fn checksum_with_init(data: &[u8], init: u32) -> u32 {
    crc32c_append(init, data)
}

/// Verify that data matches the expected checksum.
///
/// Returns true if the checksum of data equals expected.
#[inline]
pub fn verify(data: &[u8], expected: u32) -> bool {
    checksum(data) == expected
}

/// Create a new CRC32C hasher for incremental checksumming.
#[inline]
pub fn hasher() -> Crc32cHasher {
    Crc32cHasher::new()
}

#[cfg(test)]
mod tests {
    use super::*;

    // Known test vectors for CRC32C
    const TEST_VECTOR_EMPTY: u32 = 0x00000000;
    const TEST_VECTOR_123456789: u32 = 0xE3069283;
    const TEST_VECTOR_HELLO_WORLD: u32 = 0x4D551068; // CRC32C for "Hello, World!"

    #[test]
    fn test_crc32c_empty() {
        let data = b"";
        // After final XOR, empty input produces 0
        let result = checksum(data);
        assert_eq!(result, TEST_VECTOR_EMPTY);
    }

    #[test]
    fn test_crc32c_test_vector() {
        let data = b"123456789";
        let result = checksum(data);
        assert_eq!(result, TEST_VECTOR_123456789);
    }

    #[test]
    fn test_crc32c_hello_world() {
        let data = b"Hello, World!";
        let result = checksum(data);
        assert_eq!(result, TEST_VECTOR_HELLO_WORLD);
    }

    #[test]
    fn test_verify() {
        let data = b"test data";
        let expected = checksum(data);
        assert!(verify(data, expected));
        assert!(!verify(data, expected + 1));
    }

    #[test]
    fn test_deterministic() {
        let data = b"deterministic test";
        let result1 = checksum(data);
        let result2 = checksum(data);
        assert_eq!(result1, result2);
    }

    #[test]
    fn test_avalanche() {
        // Small input change should produce very different output
        let data1 = b"test data 123";
        let data2 = b"test data 124";
        let result1 = checksum(data1);
        let result2 = checksum(data2);
        // Results should differ significantly
        assert_ne!(result1, result2);
    }

    #[test]
    fn test_checksum_with_init() {
        let data1 = b"hello";
        let data2 = b"world";

        // Test incremental checksum calculation
        let mut combined_data = Vec::from(data1.as_slice());
        combined_data.extend_from_slice(data2);
        let combined = checksum(&combined_data);
        let separate = checksum_with_init(data2, checksum(data1));
        // Note: CRC32C with init should produce same result
        assert_eq!(combined, separate);
    }
}
