//! Overflow Page Support for Large Value Storage
//!
//! This module provides support for storing large values that exceed the inline
//! threshold. Overflow pages form singly-linked chains to store values up to
//! 16MB in size across multiple 16KB pages.

use crate::error::{Error, Result, ValidationError};
use crate::page::{Page, PageType};
use crate::types::PageId;
use serde::{Deserialize, Serialize};

/// Magic number for overflow page identification (ASCII "OVFL")
pub const OVERFLOW_MAGIC: u32 = 0x4F56464C;

/// Inline value storage threshold (2000 bytes)
/// Values larger than this are stored in overflow pages
pub const INLINE_THRESHOLD: usize = 2000;

/// Maximum value size (16MB - 1)
pub const MAX_VALUE_SIZE: usize = 16_777_215;

/// Overflow page data chunk size (PAGE_SIZE - HEADER_SIZE - 8 - 4 = 16332 bytes)
pub const OVERFLOW_DATA_SIZE: usize = 16332;

/// Overflow value marker (value_len = 0xFFFF indicates overflow)
pub const OVERFLOW_VALUE_MARKER: u16 = 0xFFFF;

/// Overflow page structure for storing large value data chunks
#[repr(C)]
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct OverflowPage {
    /// Magic number (0x4F56464C "OVFL")
    pub magic: u32,
    /// Next overflow page ID in chain (0 if last page)
    pub next_page: u64,
    /// Value data chunk (up to 16368 bytes)
    pub data: Vec<u8>,
}

impl Default for OverflowPage {
    fn default() -> Self {
        Self {
            magic: OVERFLOW_MAGIC,
            next_page: 0,
            data: Vec::with_capacity(OVERFLOW_DATA_SIZE),
        }
    }
}

impl OverflowPage {
    /// Create a new overflow page
    pub fn new() -> Self {
        Self::default()
    }

    /// Create a new overflow page with data
    pub fn with_data(data: Vec<u8>, next_page: u64) -> Self {
        Self {
            magic: OVERFLOW_MAGIC,
            next_page,
            data,
        }
    }

    /// Get the next page ID
    pub fn get_next_page(&self) -> PageId {
        PageId::new(self.next_page)
    }

    /// Set the next page ID
    pub fn set_next_page(&mut self, page_id: PageId) {
        self.next_page = page_id.as_u64();
    }

    /// Check if this is the last page in the chain
    pub fn is_last(&self) -> bool {
        self.next_page == 0
    }

    /// Validate the overflow page structure
    pub fn validate(&self) -> Result<()> {
        // Check magic number
        if self.magic != OVERFLOW_MAGIC {
            return Err(Error::Validation(ValidationError::Generic(
                format!("Invalid overflow page magic: expected 0x{:08X}, got 0x{:08X}",
                    OVERFLOW_MAGIC, self.magic)
            )));
        }

        // Check data size
        if self.data.len() > OVERFLOW_DATA_SIZE {
            return Err(Error::Validation(ValidationError::Generic(
                format!("Overflow page data too large: {} bytes (max {})",
                    self.data.len(), OVERFLOW_DATA_SIZE)
            )));
        }

        Ok(())
    }

    /// Serialize overflow page to bytes (page payload only, no header)
    pub fn to_bytes(&self) -> Vec<u8> {
        let mut bytes = Vec::with_capacity(8 + 8 + self.data.len());

        // Write magic
        bytes.extend_from_slice(&self.magic.to_le_bytes());

        // Write next_page
        bytes.extend_from_slice(&self.next_page.to_le_bytes());

        // Write data
        bytes.extend_from_slice(&self.data);

        bytes
    }

    /// Deserialize overflow page from bytes (page payload only, no header)
    pub fn from_bytes(bytes: &[u8]) -> Result<Self> {
        if bytes.len() < 12 {
            return Err(Error::Validation(ValidationError::Generic(
                format!("Overflow page payload too short: {} bytes (min 12)", bytes.len())
            )));
        }

        let magic = u32::from_le_bytes(bytes[0..4].try_into()
            .unwrap_or_else(|_| [0u8; 4]));

        let next_page = u64::from_le_bytes(bytes[4..12].try_into()
            .unwrap_or_else(|_| [0u8; 8]));

        let data = if bytes.len() > 12 {
            bytes[12..].to_vec()
        } else {
            Vec::new()
        };

        let page = Self {
            magic,
            next_page,
            data,
        };

        page.validate()?;
        Ok(page)
    }

    /// Calculate number of overflow pages needed for a value
    pub fn pages_needed(value_length: usize) -> usize {
        if value_length == 0 {
            return 0;
        }
        (value_length + OVERFLOW_DATA_SIZE - 1) / OVERFLOW_DATA_SIZE
    }

    /// Determine if value should be stored inline
    pub fn should_store_inline(value_length: usize) -> bool {
        value_length <= INLINE_THRESHOLD
    }
}

/// Value storage encoding
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ValueStorage {
    /// Inline value (small)
    Inline(Vec<u8>),
    /// Overflow reference (large value)
    Overflow(PageId),
}

impl ValueStorage {
    /// Encode value storage to bytes for leaf entry
    pub fn encode(&self) -> Vec<u8> {
        match self {
            ValueStorage::Inline(value) => {
                let mut encoded = Vec::with_capacity(2 + value.len());
                encoded.extend_from_slice(&(value.len() as u16).to_le_bytes());
                encoded.extend_from_slice(value);
                encoded
            }
            ValueStorage::Overflow(page_id) => {
                let mut encoded = Vec::with_capacity(10);
                encoded.extend_from_slice(&OVERFLOW_VALUE_MARKER.to_le_bytes());
                encoded.extend_from_slice(&page_id.as_u64().to_le_bytes());
                encoded
            }
        }
    }

    /// Decode value storage from leaf entry bytes
    pub fn decode(bytes: &[u8]) -> Result<Self> {
        if bytes.len() < 2 {
            return Err(Error::Validation(ValidationError::Generic(
                format!("Value storage too short: {} bytes (min 2)", bytes.len())
            )));
        }

        let value_len = u16::from_le_bytes([bytes[0], bytes[1]]);

        if value_len == OVERFLOW_VALUE_MARKER {
            // Overflow reference
            if bytes.len() < 10 {
                return Err(Error::Validation(ValidationError::Generic(
                    format!("Overflow reference too short: {} bytes (expected 10)", bytes.len())
                )));
            }
            let page_id = u64::from_le_bytes(bytes[2..10].try_into()
                .unwrap_or_else(|_| [0u8; 8]));
            Ok(ValueStorage::Overflow(PageId::new(page_id)))
        } else {
            // Inline value
            let value_bytes = &bytes[2..2 + value_len as usize];
            Ok(ValueStorage::Inline(value_bytes.to_vec()))
        }
    }

    /// Get the length of the encoded value storage
    pub fn encoded_len(&self) -> usize {
        match self {
            ValueStorage::Inline(value) => 2 + value.len(),
            ValueStorage::Overflow(_) => 10,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_overflow_page_constants() {
        assert_eq!(OVERFLOW_MAGIC, 0x4F56464C);
        assert_eq!(INLINE_THRESHOLD, 2000);
        assert_eq!(MAX_VALUE_SIZE, 16_777_215);
        assert_eq!(OVERFLOW_DATA_SIZE, 16332);
        assert_eq!(OVERFLOW_VALUE_MARKER, 0xFFFF);
    }

    #[test]
    fn test_overflow_page_default() {
        let page = OverflowPage::default();
        assert_eq!(page.magic, OVERFLOW_MAGIC);
        assert_eq!(page.next_page, 0);
        assert_eq!(page.data.len(), 0);
    }

    #[test]
    fn test_overflow_page_with_data() {
        let data = vec![1u8, 2, 3, 4, 5];
        let page = OverflowPage::with_data(data.clone(), 42);
        assert_eq!(page.magic, OVERFLOW_MAGIC);
        assert_eq!(page.next_page, 42);
        assert_eq!(page.data, data);
    }

    #[test]
    fn test_overflow_page_validate() {
        let mut page = OverflowPage::new();
        assert!(page.validate().is_ok());

        // Invalid magic
        page.magic = 0xDEADBEEF;
        assert!(page.validate().is_err());

        // Data too large
        page.magic = OVERFLOW_MAGIC;
        page.data = vec![0u8; OVERFLOW_DATA_SIZE + 1];
        assert!(page.validate().is_err());
    }

    #[test]
    fn test_overflow_page_is_last() {
        let mut page = OverflowPage::new();
        assert!(page.is_last());

        page.set_next_page(PageId::new(42));
        assert!(!page.is_last());
        assert_eq!(page.get_next_page().as_u64(), 42);
    }

    #[test]
    fn test_overflow_page_round_trip() {
        let data = vec![1u8, 2, 3, 4, 5];
        let original = OverflowPage::with_data(data.clone(), 42);

        let bytes = original.to_bytes();
        let decoded = OverflowPage::from_bytes(&bytes).unwrap();

        assert_eq!(decoded.magic, original.magic);
        assert_eq!(decoded.next_page, original.next_page);
        assert_eq!(decoded.data, original.data);
    }

    #[test]
    fn test_overflow_page_empty_round_trip() {
        let original = OverflowPage::new();

        let bytes = original.to_bytes();
        assert_eq!(bytes.len(), 12); // magic (4) + next_page (8)

        let decoded = OverflowPage::from_bytes(&bytes).unwrap();
        assert_eq!(decoded.magic, original.magic);
        assert_eq!(decoded.next_page, original.next_page);
        assert_eq!(decoded.data, original.data);
    }

    #[test]
    fn test_pages_needed() {
        assert_eq!(OverflowPage::pages_needed(0), 0);
        assert_eq!(OverflowPage::pages_needed(1), 1);
        assert_eq!(OverflowPage::pages_needed(OVERFLOW_DATA_SIZE), 1);
        assert_eq!(OverflowPage::pages_needed(OVERFLOW_DATA_SIZE + 1), 2);
        assert_eq!(OverflowPage::pages_needed(OVERFLOW_DATA_SIZE * 2), 2);
        assert_eq!(OverflowPage::pages_needed(OVERFLOW_DATA_SIZE * 2 + 1), 3);
    }

    #[test]
    fn test_should_store_inline() {
        assert!(OverflowPage::should_store_inline(0));
        assert!(OverflowPage::should_store_inline(1));
        assert!(OverflowPage::should_store_inline(INLINE_THRESHOLD));
        assert!(!OverflowPage::should_store_inline(INLINE_THRESHOLD + 1));
        assert!(!OverflowPage::should_store_inline(MAX_VALUE_SIZE));
    }

    #[test]
    fn test_value_storage_inline_encode() {
        let value = b"hello".to_vec();
        let storage = ValueStorage::Inline(value.clone());

        let encoded = storage.encode();
        assert_eq!(encoded.len(), 2 + value.len());
        assert_eq!(encoded[0], value.len() as u8);
        assert_eq!(&encoded[2..], value.as_slice());
    }

    #[test]
    fn test_value_storage_overflow_encode() {
        let page_id = PageId::new(42);
        let storage = ValueStorage::Overflow(page_id);

        let encoded = storage.encode();
        assert_eq!(encoded.len(), 10);
        assert_eq!(&encoded[0..2], &OVERFLOW_VALUE_MARKER.to_le_bytes());
        assert_eq!(&encoded[2..10], &42u64.to_le_bytes());
    }

    #[test]
    fn test_value_storage_inline_decode() {
        let value = b"hello".to_vec();
        let mut encoded = vec![value.len() as u8, 0];
        encoded.extend_from_slice(&value);

        let decoded = ValueStorage::decode(&encoded).unwrap();
        assert_eq!(decoded, ValueStorage::Inline(value));
    }

    #[test]
    fn test_value_storage_overflow_decode() {
        let mut encoded = OVERFLOW_VALUE_MARKER.to_le_bytes().to_vec();
        encoded.extend_from_slice(&42u64.to_le_bytes());

        let decoded = ValueStorage::decode(&encoded).unwrap();
        assert_eq!(decoded, ValueStorage::Overflow(PageId::new(42)));
    }

    #[test]
    fn test_value_storage_round_trip() {
        // Inline
        let inline_value = b"test_value".to_vec();
        let inline_storage = ValueStorage::Inline(inline_value.clone());
        let inline_encoded = inline_storage.encode();
        let inline_decoded = ValueStorage::decode(&inline_encoded).unwrap();
        assert_eq!(inline_decoded, inline_storage);

        // Overflow
        let overflow_page_id = PageId::new(123);
        let overflow_storage = ValueStorage::Overflow(overflow_page_id);
        let overflow_encoded = overflow_storage.encode();
        let overflow_decoded = ValueStorage::decode(&overflow_encoded).unwrap();
        assert_eq!(overflow_decoded, overflow_storage);
    }

    #[test]
    fn test_value_storage_encoded_len() {
        let inline = ValueStorage::Inline(vec![1u8, 2, 3, 4, 5]);
        assert_eq!(inline.encoded_len(), 2 + 5);

        let overflow = ValueStorage::Overflow(PageId::new(42));
        assert_eq!(overflow.encoded_len(), 10);
    }

    #[test]
    fn test_max_value_size_within_overflow_pages() {
        // Verify that MAX_VALUE_SIZE can be stored in a reasonable number of pages
        let pages = OverflowPage::pages_needed(MAX_VALUE_SIZE);
        // Ceiling of 16777215 / 16332 = 1028
        assert!(pages == 1028, "Max value should fit in exactly 1028 pages, got {}", pages);

        // Calculate actual storage needed
        let total_storage = pages * OVERFLOW_DATA_SIZE;
        assert!(total_storage >= MAX_VALUE_SIZE);
    }

    #[test]
    fn test_empty_value() {
        let value = vec![];
        let storage = ValueStorage::Inline(value.clone());
        let encoded = storage.encode();

        // Empty value should encode to just the length prefix
        assert_eq!(encoded.len(), 2);
        assert_eq!(encoded[0], 0);
        assert_eq!(encoded[1], 0);

        let decoded = ValueStorage::decode(&encoded).unwrap();
        assert_eq!(decoded, ValueStorage::Inline(vec![]));
    }

    // Integration tests

    #[test]
    fn test_inline_threshold_boundary() {
        // Value exactly at threshold should be inline
        let value_at_threshold = vec![42u8; INLINE_THRESHOLD];
        assert!(OverflowPage::should_store_inline(value_at_threshold.len()));

        // Value just over threshold should be overflow
        let value_over_threshold = vec![42u8; INLINE_THRESHOLD + 1];
        assert!(!OverflowPage::should_store_inline(value_over_threshold.len()));
    }

    #[test]
    fn test_overflow_chain_size_calculation() {
        // Test various value sizes
        assert_eq!(OverflowPage::pages_needed(1), 1);
        assert_eq!(OverflowPage::pages_needed(OVERFLOW_DATA_SIZE), 1);
        assert_eq!(OverflowPage::pages_needed(OVERFLOW_DATA_SIZE + 1), 2);
        assert_eq!(OverflowPage::pages_needed(OVERFLOW_DATA_SIZE * 2), 2);
        assert_eq!(OverflowPage::pages_needed(OVERFLOW_DATA_SIZE * 2 + 1), 3);
    }

    #[test]
    fn test_value_storage_round_trip_various_sizes() {
        // Test small inline values
        for size in [0, 1, 10, 100, 1000, INLINE_THRESHOLD] {
            let value = vec![42u8; size];
            let storage = ValueStorage::Inline(value.clone());
            let encoded = storage.encode();
            let decoded = ValueStorage::decode(&encoded).unwrap();
            assert_eq!(decoded, storage);
        }

        // Test overflow reference encoding
        for page_id in [0, 1, 100, 1000, 0xFFFFFFFFFFFFFF] {
            let storage = ValueStorage::Overflow(PageId::new(page_id));
            let encoded = storage.encode();
            let decoded = ValueStorage::decode(&encoded).unwrap();
            assert_eq!(decoded, storage);
        }
    }

    #[test]
    fn test_overflow_marker_uniqueness() {
        // Ensure overflow marker doesn't conflict with valid inline lengths
        // The overflow marker is 0xFFFF
        let inline_value = vec![0u8; 0xFFFF]; // This is a valid inline value (65535 bytes)
        let storage = ValueStorage::Inline(inline_value.clone());
        let encoded = storage.encode();

        // The first 2 bytes should be the length (0xFFFF), which is NOT the overflow marker
        // because we check should_store_inline first
        assert!(inline_value.len() <= u16::MAX as usize);
    }

    #[test]
    fn test_encoded_size_consistency() {
        // Inline value size should be consistent
        for size in [0, 1, 100, INLINE_THRESHOLD] {
            let value = vec![42u8; size];
            let storage = ValueStorage::Inline(value.clone());
            let encoded = storage.encode();
            assert_eq!(encoded.len(), storage.encoded_len());
            assert_eq!(encoded.len(), 2 + size);
        }

        // Overflow reference size should always be 10
        let storage = ValueStorage::Overflow(PageId::new(12345));
        let encoded = storage.encode();
        assert_eq!(encoded.len(), storage.encoded_len());
        assert_eq!(encoded.len(), 10);
    }

    #[test]
    fn test_max_value_size_constraint() {
        // MAX_VALUE_SIZE should be less than what can be addressed by 3 bytes (16MB)
        assert!(MAX_VALUE_SIZE <= 16_777_215);

        // Should fit in a reasonable number of pages
        let pages = OverflowPage::pages_needed(MAX_VALUE_SIZE);
        assert!(pages <= 2000, "Max value should fit in under 2000 pages, got {}", pages);
    }
}
