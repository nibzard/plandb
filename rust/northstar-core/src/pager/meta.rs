//! Meta page handling and metadata state management.
//!
//! Provides structures for meta page payloads and state tracking,
//! including dual meta page handling for atomic updates.

use crate::checksum;
use crate::error::{Error, Result, ValidationError};
use crate::page::{Page, PageHeader, PageType};
use crate::types::{Lsn, PageId, TransactionId};
use std::fmt::{Debug, Formatter};

/// Magic number for meta page payload (ASCII "META")
pub const META_MAGIC: u32 = 0x4D455441;

/// Size of MetaPayload structure in bytes
pub const META_PAYLOAD_SIZE: usize = 48;

/// Meta page payload - database metadata stored in meta pages
#[repr(C)]
#[derive(Copy, Clone, Debug, PartialEq, Eq)]
pub struct MetaPayload {
    /// Magic number (0x4D455441 "META")
    pub meta_magic: u32,
    /// Meta format version
    pub format_version: u16,
    /// Database page size (typically 16384)
    pub page_size: u16,
    /// Highest committed transaction ID
    pub committed_txn_id: u64,
    /// Root page ID of B+tree (0 if empty)
    pub root_page_id: u64,
    /// Head of free list page chain (0 if none)
    pub freelist_head_page_id: u64,
    /// Log tail LSN (WAL position)
    pub log_tail_lsn: u64,
    /// Meta payload checksum
    pub meta_crc32c: u32,
}

impl Default for MetaPayload {
    fn default() -> Self {
        Self {
            meta_magic: META_MAGIC,
            format_version: 0,
            page_size: crate::page::PAGE_SIZE as u16,
            committed_txn_id: 0,
            root_page_id: crate::PageId::FIRST_DATA.as_u64(),
            freelist_head_page_id: 0,
            log_tail_lsn: 0,
            meta_crc32c: 0,
        }
    }
}

impl MetaPayload {
    /// Create a new meta payload with default values
    pub fn new() -> Self {
        Self::default()
    }

    /// Validate the meta payload structure
    pub fn validate(&self) -> Result<()> {
        // Check magic number
        if self.meta_magic != META_MAGIC {
            return Err(Error::Validation(ValidationError::InvalidMagic {
                expected: META_MAGIC,
                actual: self.meta_magic,
            }));
        }

        // Check format version (only 0 supported)
        if self.format_version != 0 {
            return Err(Error::Validation(ValidationError::UnsupportedVersion {
                major: self.format_version as u16,
                minor: 0,
                patch: 0,
            }));
        }

        // Check page size is power of 2 and at least 4096
        if self.page_size < 4096 || !self.page_size.is_power_of_two() {
            return Err(Error::Validation(ValidationError::Generic(format!(
                "Invalid page size: {} (must be power of 2 and >= 4096)",
                self.page_size
            ))));
        }

        Ok(())
    }

    /// Calculate the meta payload checksum
    pub fn calculate_checksum(&self) -> u32 {
        // Create bytes representation with checksum field zeroed
        let bytes = unsafe {
            // Safe because we're treating the struct as bytes and zeroing checksum field
            let mut copy = *self;
            copy.meta_crc32c = 0;
            let ptr = &copy as *const Self as *const u8;
            std::slice::from_raw_parts(ptr, META_PAYLOAD_SIZE)
        };
        checksum::checksum(bytes)
    }

    /// Validate the meta payload checksum
    pub fn validate_checksum(&self) -> bool {
        let stored = self.meta_crc32c;
        let calculated = self.calculate_checksum();
        stored == calculated
    }

    /// Update the checksum after modifying fields
    pub fn update_checksum(&mut self) {
        self.meta_crc32c = self.calculate_checksum();
    }

    /// Get the committed transaction ID
    pub fn committed_txn_id(&self) -> TransactionId {
        TransactionId::new(self.committed_txn_id)
    }

    /// Get the root page ID
    pub fn root_page_id(&self) -> PageId {
        PageId::new(self.root_page_id)
    }

    /// Get the free list head page ID
    pub fn freelist_head_page_id(&self) -> PageId {
        PageId::new(self.freelist_head_page_id)
    }

    /// Get the log tail LSN
    pub fn log_tail_lsn(&self) -> Lsn {
        Lsn::new(self.log_tail_lsn)
    }

    /// Encode meta payload to bytes
    pub fn to_bytes(&self) -> [u8; META_PAYLOAD_SIZE] {
        unsafe {
            let mut bytes = [0u8; META_PAYLOAD_SIZE];
            let ptr = bytes.as_mut_ptr() as *mut Self;
            ptr.write_unaligned(*self);
            bytes
        }
    }

    /// Decode meta payload from bytes
    pub fn from_bytes(bytes: &[u8]) -> Result<Self> {
        if bytes.len() < META_PAYLOAD_SIZE {
            return Err(Error::Validation(ValidationError::InvalidHeaderSize {
                expected: META_PAYLOAD_SIZE,
                actual: bytes.len(),
            }));
        }

        unsafe {
            let ptr = bytes.as_ptr() as *const Self;
            let payload = ptr.read_unaligned();
            payload.validate()?;
            Ok(payload)
        }
    }
}

/// Meta state - represents the state of a meta page
#[derive(Clone, PartialEq, Eq)]
pub struct MetaState {
    /// Page ID (0 for META_A, 1 for META_B)
    pub page_id: PageId,
    /// Page header
    pub header: PageHeader,
    /// Meta payload
    pub meta: MetaPayload,
}

impl MetaState {
    /// Create a new meta state
    pub fn new(page_id: PageId) -> Self {
        let mut header = PageHeader::new(page_id, PageType::Meta);
        let mut meta = MetaPayload::new();

        // Initialize payload and set length
        let meta_bytes = meta.to_bytes();
        header.payload_len = META_PAYLOAD_SIZE as u32;

        // Calculate checksums
        meta.update_checksum();
        header.update_checksum();

        Self { page_id, header, meta }
    }

    /// Create meta state from page
    pub fn from_page(page: &Page) -> Result<Self> {
        // Validate page type
        if page.page_type() != Some(PageType::Meta) {
            return Err(Error::Validation(ValidationError::InvalidPageType {
                page_type: page.header.page_type,
            }));
        }

        // Parse meta payload from page data
        let meta = MetaPayload::from_bytes(&page.payload)?;

        Ok(Self {
            page_id: page.page_id(),
            header: page.header,
            meta,
        })
    }

    /// Validate the complete meta state
    pub fn validate(&self) -> Result<()> {
        // Check page ID matches
        if self.header.page_id != self.page_id.as_u64() {
            return Err(Error::Validation(ValidationError::Generic(format!(
                "Page ID mismatch: header={}, state={}",
                self.header.page_id,
                self.page_id.as_u64()
            ))));
        }

        // Validate header
        self.header.validate()?;

        // Validate meta payload
        self.meta.validate()?;

        // Validate meta checksum
        if !self.meta.validate_checksum() {
            return Err(Error::Validation(ValidationError::ChecksumMismatch {
                expected: self.meta.meta_crc32c,
                actual: self.meta.calculate_checksum(),
            }));
        }

        Ok(())
    }

    /// Check if this meta state is valid (complete validation)
    pub fn is_valid(&self) -> bool {
        self.validate().is_ok()
    }

    /// Check if this appears to be a torn write
    pub fn is_torn_write(&self) -> bool {
        // Heuristic: if committed_txn_id is unreasonably large compared to page_id
        // or root_page_id is beyond reasonable bounds, it might be torn
        const MAX_REASONABLE_TXN: u64 = 1_000_000_000_000; // 1 trillion
        const MAX_REASONABLE_PAGE: u64 = 1_000_000_000; // 1 billion pages

        if self.meta.committed_txn_id > MAX_REASONABLE_TXN {
            return true;
        }

        if self.meta.root_page_id > MAX_REASONABLE_PAGE {
            return true;
        }

        false
    }

    /// Get the committed transaction ID
    pub fn committed_txn_id(&self) -> TransactionId {
        self.meta.committed_txn_id()
    }

    /// Get the root page ID
    pub fn root_page_id(&self) -> PageId {
        self.meta.root_page_id()
    }

    /// Get the free list head page ID
    pub fn freelist_head_page_id(&self) -> PageId {
        self.meta.freelist_head_page_id()
    }

    /// Get the log tail LSN
    pub fn log_tail_lsn(&self) -> Lsn {
        self.meta.log_tail_lsn()
    }

    /// Get the page size
    pub fn page_size(&self) -> u16 {
        self.meta.page_size
    }

    /// Convert to Page
    pub fn to_page(&self) -> Page {
        let mut page = Page::new(self.page_id, PageType::Meta);
        page.header = self.header;

        // Encode meta payload to bytes
        let meta_bytes = self.meta.to_bytes();
        page.payload = meta_bytes.to_vec();
        page.header.payload_len = page.payload.len() as u32;

        // Recalculate checksums
        page.recalculate_checksums();

        page
    }

    /// Update the committed transaction ID and recalculate checksums
    pub fn update_committed_txn_id(&mut self, txn_id: TransactionId) {
        self.meta.committed_txn_id = txn_id.as_u64();
        self.meta.update_checksum();

        // Update header checksum since payload changed
        self.header.payload_len = META_PAYLOAD_SIZE as u32;
        self.header.update_checksum();
    }

    /// Update the root page ID and recalculate checksums
    pub fn update_root_page_id(&mut self, page_id: PageId) {
        self.meta.root_page_id = page_id.as_u64();
        self.meta.update_checksum();

        // Update header checksum since payload changed
        self.header.payload_len = META_PAYLOAD_SIZE as u32;
        self.header.update_checksum();
    }

    /// Update the log tail LSN and recalculate checksums
    pub fn update_log_tail_lsn(&mut self, lsn: Lsn) {
        self.meta.log_tail_lsn = lsn.as_u64();
        self.meta.update_checksum();

        // Update header checksum since payload changed
        self.header.payload_len = META_PAYLOAD_SIZE as u32;
        self.header.update_checksum();
    }
}

impl Debug for MetaState {
    fn fmt(&self, f: &mut Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("MetaState")
            .field("page_id", &self.page_id)
            .field("committed_txn_id", &self.meta.committed_txn_id)
            .field("root_page_id", &self.meta.root_page_id)
            .field("freelist_head", &self.meta.freelist_head_page_id)
            .field("log_tail_lsn", &self.meta.log_tail_lsn)
            .field("page_size", &self.meta.page_size)
            .finish()
    }
}

/// Choose the best meta state from two candidates
///
/// Returns the meta state with the higher committed transaction ID,
/// or None if both are invalid.
pub fn choose_best_meta<'a>(
    meta_a: Option<&'a MetaState>,
    meta_b: Option<&'a MetaState>,
) -> Option<&'a MetaState> {
    match (meta_a, meta_b) {
        (None, None) => None,
        (Some(a), None) => Some(a),
        (None, Some(b)) => Some(b),
        (Some(a), Some(b)) => {
            // Check for torn writes
            let a_torn = a.is_torn_write();
            let b_torn = b.is_torn_write();

            if a_torn && b_torn {
                // Both appear torn - prefer the one with lower txn_id (more likely complete)
                if a.committed_txn_id().as_u64() <= b.committed_txn_id().as_u64() {
                    Some(a)
                } else {
                    Some(b)
                }
            } else if a_torn {
                Some(b)
            } else if b_torn {
                Some(a)
            } else {
                // Both valid - choose higher txn_id
                if a.committed_txn_id() > b.committed_txn_id() {
                    Some(a)
                } else {
                    Some(b)
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_meta_payload_default() {
        let payload = MetaPayload::default();
        assert_eq!(payload.meta_magic, META_MAGIC);
        assert_eq!(payload.format_version, 0);
        assert_eq!(payload.page_size, crate::page::PAGE_SIZE as u16);
        assert_eq!(payload.committed_txn_id, 0);
        assert_eq!(payload.root_page_id, crate::PageId::FIRST_DATA.as_u64());
    }

    #[test]
    fn test_meta_payload_validate() {
        let payload = MetaPayload::new();
        assert!(payload.validate().is_ok());

        // Wrong magic
        let mut bad_payload = payload;
        bad_payload.meta_magic = 0xDEADBEEF;
        assert!(bad_payload.validate().is_err());
    }

    #[test]
    fn test_meta_payload_checksum() {
        let mut payload = MetaPayload::new();
        payload.update_checksum();

        assert!(payload.validate_checksum());

        // Corrupt checksum
        payload.meta_crc32c = 0xDEADBEEF;
        assert!(!payload.validate_checksum());
    }

    #[test]
    fn test_meta_payload_round_trip() {
        let mut original = MetaPayload::new();
        original.committed_txn_id = 42;
        original.root_page_id = 10;
        original.update_checksum();

        let bytes = original.to_bytes();
        let decoded = MetaPayload::from_bytes(&bytes).unwrap();

        assert_eq!(decoded, original);
    }

    #[test]
    fn test_meta_state_new() {
        let state = MetaState::new(PageId::META_A);
        assert_eq!(state.page_id, PageId::META_A);
        assert_eq!(state.header.page_type, PageType::Meta as u8);
        assert!(state.validate().is_ok());
    }

    #[test]
    fn test_meta_state_from_page() {
        let mut page = Page::new(PageId::META_A, PageType::Meta);
        let mut meta_payload = MetaPayload::new();
        meta_payload.update_checksum(); // Calculate checksum
        page.payload = meta_payload.to_bytes().to_vec();
        page.header.payload_len = page.payload.len() as u32;
        page.recalculate_checksums();

        let state = MetaState::from_page(&page).unwrap();
        assert_eq!(state.page_id, PageId::META_A);
        assert!(state.validate().is_ok());
    }

    #[test]
    fn test_meta_state_to_page() {
        let state = MetaState::new(PageId::META_B);
        let page = state.to_page();

        assert_eq!(page.page_id(), PageId::META_B);
        assert_eq!(page.page_type(), Some(PageType::Meta));
        assert!(page.validate().is_ok());
    }

    #[test]
    fn test_meta_state_update_txn_id() {
        let mut state = MetaState::new(PageId::META_A);
        state.update_committed_txn_id(TransactionId::new(42));

        assert_eq!(state.committed_txn_id().as_u64(), 42);
        assert!(state.validate().is_ok());
    }

    #[test]
    fn test_meta_state_update_root_page_id() {
        let mut state = MetaState::new(PageId::META_A);
        state.update_root_page_id(PageId::new(100));

        assert_eq!(state.root_page_id().as_u64(), 100);
        assert!(state.validate().is_ok());
    }

    #[test]
    fn test_choose_best_meta() {
        let mut meta_a = MetaState::new(PageId::META_A);
        meta_a.update_committed_txn_id(TransactionId::new(10));

        let mut meta_b = MetaState::new(PageId::META_B);
        meta_b.update_committed_txn_id(TransactionId::new(20));

        // B has higher txn_id
        assert_eq!(
            choose_best_meta(Some(&meta_a), Some(&meta_b)),
            Some(&meta_b)
        );

        // Only A valid
        assert_eq!(
            choose_best_meta(Some(&meta_a), None),
            Some(&meta_a)
        );

        // Only B valid
        assert_eq!(
            choose_best_meta(None, Some(&meta_b)),
            Some(&meta_b)
        );

        // Both None
        assert_eq!(choose_best_meta(None, None), None);
    }

    #[test]
    fn test_torn_write_detection() {
        let mut state = MetaState::new(PageId::META_A);

        // Normal state is not torn
        assert!(!state.is_torn_write());

        // Unreasonably large txn_id
        state.meta.committed_txn_id = 1_000_000_000_001;
        assert!(state.is_torn_write());

        // Unreasonably large root page ID
        state.meta.committed_txn_id = 0;
        state.meta.root_page_id = 1_000_000_001;
        assert!(state.is_torn_write());
    }

    #[test]
    fn test_meta_state_round_trip() {
        let mut original_state = MetaState::new(PageId::META_B);
        original_state.update_committed_txn_id(TransactionId::new(100));
        original_state.update_root_page_id(PageId::new(42));

        let page = original_state.to_page();
        let restored_state = MetaState::from_page(&page).unwrap();

        assert_eq!(restored_state.page_id, original_state.page_id);
        assert_eq!(
            restored_state.committed_txn_id(),
            original_state.committed_txn_id()
        );
        assert_eq!(
            restored_state.root_page_id(),
            original_state.root_page_id()
        );
    }
}
