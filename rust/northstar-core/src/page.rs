//! Page types and structures for NorthstarDB storage.
//!
//! Pages are the fundamental unit of I/O, with a fixed size of 16KB.
//! Each page contains a header with metadata and checksums, followed
//! by a payload area for type-specific data.

use crate::checksum;
use crate::error::{Error, Result, ValidationError};
use crate::types::PageId;
use serde::{Deserialize, Serialize};
use std::fmt::{self, Debug, Formatter};

/// Magic number for page identification (ASCII "NSDB")
pub const PAGE_MAGIC: u32 = 0x4E534442;

/// Current page format version
pub const FORMAT_VERSION: u16 = 0;

/// Standard page size (16KB)
pub const PAGE_SIZE: usize = 16384;

/// Page header size (40 bytes)
pub const HEADER_SIZE: usize = 40;

/// Maximum payload size
pub const MAX_PAYLOAD_SIZE: usize = PAGE_SIZE - HEADER_SIZE;

/// Page type enumeration
#[repr(u8)]
#[derive(Copy, Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum PageType {
    /// Meta page - stores database metadata
    Meta = 0,
    /// Internal B+tree node
    BtreeInternal = 1,
    /// B+tree leaf node
    BtreeLeaf = 2,
    /// Free page list
    Freelist = 3,
    /// WAL log segment
    LogSegment = 4,
    /// Overflow page for large values
    Overflow = 5,
}

impl PageType {
    /// Convert from u8 to PageType
    pub fn from_u8(value: u8) -> Option<Self> {
        match value {
            0 => Some(Self::Meta),
            1 => Some(Self::BtreeInternal),
            2 => Some(Self::BtreeLeaf),
            3 => Some(Self::Freelist),
            4 => Some(Self::LogSegment),
            5 => Some(Self::Overflow),
            _ => None,
        }
    }

    /// Convert to u8
    pub const fn to_u8(self) -> u8 {
        self as u8
    }
}

impl TryFrom<u8> for PageType {
    type Error = Error;

    fn try_from(value: u8) -> std::result::Result<Self, Self::Error> {
        Self::from_u8(value).ok_or(Error::Validation(ValidationError::InvalidPageType { page_type: value }))
    }
}

/// Page header - fixed-size metadata at the start of each page
#[repr(C)]
#[derive(Copy, Clone, Debug, PartialEq, Eq)]
pub struct PageHeader {
    /// Magic number (0x4E534442 "NSDB")
    pub magic: u32,
    /// Format version
    pub format_version: u16,
    /// Page type
    pub page_type: u8,
    /// Page flags (reserved)
    pub flags: u8,
    /// Unique page identifier
    pub page_id: u64,
    /// Last modifying transaction ID
    pub txn_id: u64,
    /// Valid payload bytes
    pub payload_len: u32,
    /// Header checksum
    pub header_crc32c: u32,
    /// Payload checksum
    pub page_crc32c: u32,
}

impl Default for PageHeader {
    fn default() -> Self {
        Self {
            magic: PAGE_MAGIC,
            format_version: FORMAT_VERSION,
            page_type: 0,
            flags: 0,
            page_id: 0,
            txn_id: 0,
            payload_len: 0,
            header_crc32c: 0,
            page_crc32c: 0,
        }
    }
}

impl PageHeader {
    /// Create a new page header with the given properties
    pub fn new(page_id: PageId, page_type: PageType) -> Self {
        Self {
            magic: PAGE_MAGIC,
            format_version: FORMAT_VERSION,
            page_type: page_type.to_u8(),
            flags: 0,
            page_id: page_id.as_u64(),
            txn_id: 0,
            payload_len: 0,
            header_crc32c: 0,
            page_crc32c: 0,
        }
    }

    /// Get the page type
    pub fn get_page_type(&self) -> Option<PageType> {
        PageType::from_u8(self.page_type)
    }

    /// Get the page ID
    pub fn get_page_id(&self) -> PageId {
        PageId::new(self.page_id)
    }

    /// Calculate the header checksum
    pub fn calculate_header_checksum(&self) -> u32 {
        // Create bytes representation with checksum fields zeroed
        let bytes = unsafe {
            // Safe because we're treating the struct as bytes and only reading first 28 bytes
            let ptr = self as *const Self as *const u8;
            std::slice::from_raw_parts(ptr, 28)
        };
        checksum::checksum(bytes)
    }

    /// Validate the header checksum
    pub fn validate_header_checksum(&self) -> bool {
        let stored = self.header_crc32c;
        let calculated = self.calculate_header_checksum();
        stored == calculated
    }

    /// Validate the header structure
    pub fn validate(&self) -> Result<()> {
        // Check magic number
        if self.magic != PAGE_MAGIC {
            return Err(Error::Validation(ValidationError::InvalidMagic {
                expected: PAGE_MAGIC,
                actual: self.magic,
            }));
        }

        // Check format version
        if self.format_version != FORMAT_VERSION {
            return Err(Error::Validation(ValidationError::UnsupportedVersion {
                major: self.format_version,
                minor: 0,
                patch: 0,
            }));
        }

        // Check page type
        if PageType::from_u8(self.page_type).is_none() {
            return Err(Error::Validation(ValidationError::InvalidPageType {
                page_type: self.page_type,
            }));
        }

        // Check payload length
        if self.payload_len as usize > MAX_PAYLOAD_SIZE {
            return Err(Error::Validation(ValidationError::PayloadLengthInvalid {
                len: self.payload_len,
                max: MAX_PAYLOAD_SIZE as u32,
            }));
        }

        // Check header checksum
        if !self.validate_header_checksum() {
            return Err(Error::Validation(ValidationError::HeaderChecksumMismatch {
                expected: self.header_crc32c,
                actual: self.calculate_header_checksum(),
            }));
        }

        Ok(())
    }

    /// Update header checksum after modifying fields
    pub fn update_checksum(&mut self) {
        self.header_crc32c = self.calculate_header_checksum();
    }
}

/// A complete page with header and payload
#[derive(Clone, PartialEq, Eq)]
pub struct Page {
    /// Page header
    pub header: PageHeader,
    /// Payload data
    pub payload: Vec<u8>,
}

impl Page {
    /// Create a new page with the given properties
    pub fn new(page_id: PageId, page_type: PageType) -> Self {
        let header = PageHeader::new(page_id, page_type);
        let payload = Vec::with_capacity(MAX_PAYLOAD_SIZE);
        Self { header, payload }
    }

    /// Create a page from raw bytes
    pub fn from_bytes(bytes: &[u8]) -> Result<Self> {
        if bytes.len() != PAGE_SIZE {
            return Err(Error::Validation(ValidationError::InvalidHeaderSize {
                expected: PAGE_SIZE,
                actual: bytes.len(),
            }));
        }

        // Parse header
        let header = unsafe {
            let ptr = bytes.as_ptr() as *const PageHeader;
            ptr.read_unaligned()
        };

        // Validate header
        header.validate()?;

        // Extract payload
        let payload_len = header.payload_len as usize;
        let payload_start = HEADER_SIZE;
        let payload_end = payload_start + payload_len;

        if payload_end > bytes.len() {
            return Err(Error::Validation(ValidationError::PayloadLengthInvalid {
                len: header.payload_len,
                max: MAX_PAYLOAD_SIZE as u32,
            }));
        }

        let payload = bytes[payload_start..payload_end].to_vec();

        // Validate payload checksum
        let calculated = checksum::checksum(&payload);
        if calculated != header.page_crc32c {
            return Err(Error::Validation(ValidationError::ChecksumMismatch {
                expected: header.page_crc32c,
                actual: calculated,
            }));
        }

        Ok(Self { header, payload })
    }

    /// Convert page to raw bytes
    pub fn to_bytes(&self) -> [u8; PAGE_SIZE] {
        let mut bytes = [0u8; PAGE_SIZE];

        // Write header
        unsafe {
            let ptr = bytes.as_mut_ptr() as *mut PageHeader;
            ptr.write_unaligned(self.header);
        }

        // Write payload
        let payload_len = self.payload.len().min(MAX_PAYLOAD_SIZE);
        bytes[HEADER_SIZE..HEADER_SIZE + payload_len]
            .copy_from_slice(&self.payload[..payload_len]);

        bytes
    }

    /// Get the page ID
    pub fn page_id(&self) -> PageId {
        self.header.get_page_id()
    }

    /// Get the page type
    pub fn page_type(&self) -> Option<PageType> {
        self.header.get_page_type()
    }

    /// Get the transaction ID that last modified this page
    pub fn txn_id(&self) -> u64 {
        self.header.txn_id
    }

    /// Set the transaction ID
    pub fn set_txn_id(&mut self, txn_id: u64) {
        self.header.txn_id = txn_id;
    }

    /// Update the payload and recalculate checksums
    pub fn update_payload(&mut self, payload: Vec<u8>) -> Result<()> {
        if payload.len() > MAX_PAYLOAD_SIZE {
            return Err(Error::Validation(ValidationError::PayloadLengthInvalid {
                len: payload.len() as u32,
                max: MAX_PAYLOAD_SIZE as u32,
            }));
        }

        self.payload = payload;
        self.header.payload_len = self.payload.len() as u32;
        self.recalculate_checksums();
        Ok(())
    }

    /// Recalculate both checksums
    pub fn recalculate_checksums(&mut self) {
        // Calculate payload checksum
        self.header.page_crc32c = checksum::checksum(&self.payload);
        // Calculate header checksum
        self.header.update_checksum();
    }

    /// Validate the entire page
    pub fn validate(&self) -> Result<()> {
        self.header.validate()?;

        // Check payload length matches declared length
        if self.payload.len() != self.header.payload_len as usize {
            return Err(Error::Validation(ValidationError::PayloadLengthInvalid {
                len: self.header.payload_len,
                max: self.payload.len() as u32,
            }));
        }

        // Check payload checksum
        let calculated = checksum::checksum(&self.payload);
        if calculated != self.header.page_crc32c {
            return Err(Error::Validation(ValidationError::ChecksumMismatch {
                expected: self.header.page_crc32c,
                actual: calculated,
            }));
        }

        Ok(())
    }
}

impl Debug for Page {
    fn fmt(&self, f: &mut Formatter<'_>) -> fmt::Result {
        f.debug_struct("Page")
            .field("page_id", &self.page_id())
            .field("page_type", &self.page_type())
            .field("txn_id", &self.txn_id())
            .field("payload_len", &self.payload.len())
            .finish()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_page_type_conversion() {
        assert_eq!(PageType::from_u8(0), Some(PageType::Meta));
        assert_eq!(PageType::from_u8(1), Some(PageType::BtreeInternal));
        assert_eq!(PageType::from_u8(2), Some(PageType::BtreeLeaf));
        assert_eq!(PageType::from_u8(3), Some(PageType::Freelist));
        assert_eq!(PageType::from_u8(4), Some(PageType::LogSegment));
        assert_eq!(PageType::from_u8(5), Some(PageType::Overflow));
        assert_eq!(PageType::from_u8(6), None);

        assert_eq!(PageType::Meta.to_u8(), 0);
        assert_eq!(PageType::BtreeLeaf.to_u8(), 2);
        assert_eq!(PageType::Overflow.to_u8(), 5);
    }

    #[test]
    fn test_page_header_default() {
        let header = PageHeader::default();
        assert_eq!(header.magic, PAGE_MAGIC);
        assert_eq!(header.format_version, FORMAT_VERSION);
        assert_eq!(header.payload_len, 0);
    }

    #[test]
    fn test_page_header_new() {
        let page_id = PageId::new(42);
        let header = PageHeader::new(page_id, PageType::BtreeLeaf);
        assert_eq!(header.magic, PAGE_MAGIC);
        assert_eq!(header.page_id, 42);
        assert_eq!(header.page_type, 2);
    }

    #[test]
    fn test_page_header_checksum() {
        let mut header = PageHeader::new(PageId::new(10), PageType::Meta);
        header.update_checksum();
        assert!(header.validate_header_checksum());
    }

    #[test]
    fn test_page_header_validate_invalid_magic() {
        let mut header = PageHeader::new(PageId::new(0), PageType::Meta);
        header.magic = 0xDEADBEEF;
        assert!(matches!(
            header.validate(),
            Err(Error::Validation(ValidationError::InvalidMagic { .. }))
        ));
    }

    #[test]
    fn test_page_new() {
        let page_id = PageId::new(5);
        let page = Page::new(page_id, PageType::Freelist);
        assert_eq!(page.page_id(), page_id);
        assert_eq!(page.page_type(), Some(PageType::Freelist));
        assert_eq!(page.payload.len(), 0);
    }

    #[test]
    fn test_page_update_payload() {
        let mut page = Page::new(PageId::new(1), PageType::BtreeLeaf);
        let payload = b"test payload data".to_vec();
        page.update_payload(payload.clone()).unwrap();

        assert_eq!(page.payload, payload);
        assert!(page.validate().is_ok());
    }

    #[test]
    fn test_page_round_trip() {
        let page_id = PageId::new(100);
        let mut page = Page::new(page_id, PageType::BtreeInternal);
        let payload = b"some test data for the payload".to_vec();
        page.update_payload(payload).unwrap();

        // Convert to bytes
        let bytes = page.to_bytes();

        // Parse back
        let parsed = Page::from_bytes(&bytes).unwrap();

        assert_eq!(parsed.page_id(), page_id);
        assert_eq!(parsed.page_type(), Some(PageType::BtreeInternal));
        assert_eq!(parsed.payload, page.payload);
    }

    #[test]
    fn test_page_checksum_mismatch() {
        let mut page = Page::new(PageId::new(1), PageType::Meta);
        page.payload = b"corrupt data".to_vec();
        page.header.payload_len = page.payload.len() as u32;
        page.header.page_crc32c = 0xDEADBEEF; // Wrong checksum

        // Recalculate header checksum so header validation passes
        page.header.update_checksum();

        let bytes = page.to_bytes();
        assert!(matches!(
            Page::from_bytes(&bytes),
            Err(Error::Validation(ValidationError::ChecksumMismatch { .. }))
        ));
    }

    #[test]
    fn test_page_txn_id() {
        let mut page = Page::new(PageId::new(1), PageType::BtreeLeaf);
        assert_eq!(page.txn_id(), 0);

        page.set_txn_id(42);
        assert_eq!(page.txn_id(), 42);
    }
}
