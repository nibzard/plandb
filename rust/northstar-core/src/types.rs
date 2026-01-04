//! Core type definitions for NorthstarDB.
//!
//! This module provides strongly-typed wrappers around u64 identifiers
//! to prevent accidental mixing of PageId, TransactionId, and LSN values.

use serde::{Deserialize, Serialize};
use std::fmt::{self, Debug, Display, Formatter};

/// Page identifier - unique identifier for a page within the database.
///
/// PageId wraps a u64 to provide type safety and prevent confusion with
/// other identifier types like TransactionId or LSN.
#[repr(transparent)]
#[derive(Copy, Clone, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
pub struct PageId(u64);

impl PageId {
    /// First meta page (primary metadata)
    pub const META_A: Self = Self(0);

    /// Second meta page (alternate for atomic updates)
    pub const META_B: Self = Self(1);

    /// First available data page
    pub const FIRST_DATA: Self = Self(2);

    /// Construct a new PageId from a raw u64 value.
    #[inline]
    pub const fn new(id: u64) -> Self {
        Self(id)
    }

    /// Extract the raw u64 value from this PageId.
    #[inline]
    pub const fn as_u64(self) -> u64 {
        self.0
    }

    /// Check if this PageId refers to a meta page (0 or 1).
    #[inline]
    pub const fn is_meta_page(self) -> bool {
        self.0 == 0 || self.0 == 1
    }

    /// Check if this is the null/invalid PageId.
    #[inline]
    pub const fn is_null(self) -> bool {
        self.0 == 0
    }

    /// Check if this is a data page (ID >= 2).
    #[inline]
    pub const fn is_data_page(self) -> bool {
        self.0 >= 2
    }

    /// Get the next sequential PageId.
    #[inline]
    pub fn next(self) -> Option<Self> {
        self.0.checked_add(1).map(Self)
    }

    /// Calculate the byte offset of this page within the database file.
    #[inline]
    pub const fn file_offset(self, page_size: u64) -> u64 {
        self.0 * page_size
    }

    /// Get the opposite meta page ID, if this is a meta page.
    #[inline]
    pub const fn opposite_meta_id(self) -> Option<Self> {
        if self.0 == 0 {
            Some(Self(1))
        } else if self.0 == 1 {
            Some(Self(0))
        } else {
            None
        }
    }
}

impl Debug for PageId {
    fn fmt(&self, f: &mut Formatter<'_>) -> fmt::Result {
        write!(f, "PageId({})", self.0)
    }
}

impl Display for PageId {
    fn fmt(&self, f: &mut Formatter<'_>) -> fmt::Result {
        write!(f, "page {}", self.0)
    }
}

impl From<u64> for PageId {
    fn from(value: u64) -> Self {
        Self(value)
    }
}

impl From<usize> for PageId {
    fn from(value: usize) -> Self {
        Self(value as u64)
    }
}

/// Log Sequence Number - unique identifier for a WAL record position.
///
/// LSN increases monotonically as records are appended to the WAL.
/// Each WAL record carries its LSN for ordering and recovery.
#[repr(transparent)]
#[derive(Copy, Clone, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
pub struct Lsn(u64);

impl Lsn {
    /// Initial LSN value before any records are written.
    pub const INITIAL: Self = Self(0);

    /// First valid LSN (first WAL record).
    pub const FIRST: Self = Self(1);

    /// Construct a new Lsn from a raw u64 value.
    #[inline]
    pub const fn new(lsn: u64) -> Self {
        Self(lsn)
    }

    /// Extract the raw u64 value from this Lsn.
    #[inline]
    pub const fn as_u64(self) -> u64 {
        self.0
    }

    /// Check if this Lsn represents a valid log position (non-zero).
    #[inline]
    pub const fn is_valid(self) -> bool {
        self.0 > 0
    }

    /// Check if this is the initial LSN (before any records).
    #[inline]
    pub const fn is_initial(self) -> bool {
        self.0 == 0
    }

    /// Get the next sequential Lsn.
    #[inline]
    pub fn next(self) -> Option<Self> {
        self.0.checked_add(1).map(Self)
    }

    /// Calculate the number of records between two LSNs.
    ///
    /// Returns Some if other >= self, None if underflow would occur.
    #[inline]
    pub fn distance_to(self, other: Self) -> Option<u64> {
        other.0.checked_sub(self.0)
    }

    /// Convert to little-endian bytes.
    #[inline]
    pub const fn to_le_bytes(self) -> [u8; 8] {
        self.0.to_le_bytes()
    }

    /// Create Lsn from little-endian bytes.
    #[inline]
    pub const fn from_le_bytes(bytes: [u8; 8]) -> Self {
        Self(u64::from_le_bytes(bytes))
    }
}

impl Debug for Lsn {
    fn fmt(&self, f: &mut Formatter<'_>) -> fmt::Result {
        write!(f, "Lsn({})", self.0)
    }
}

impl Display for Lsn {
    fn fmt(&self, f: &mut Formatter<'_>) -> fmt::Result {
        write!(f, "LSN {}", self.0)
    }
}

impl From<u64> for Lsn {
    fn from(value: u64) -> Self {
        Self(value)
    }
}

/// Transaction identifier - unique identifier for a transaction.
///
/// TransactionId is allocated sequentially and provides ordering
/// for MVCC visibility and conflict detection.
#[repr(transparent)]
#[derive(Copy, Clone, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
pub struct TransactionId(u64);

impl TransactionId {
    /// Initial TransactionId (no transaction).
    pub const INITIAL: Self = Self(0);

    /// First valid TransactionId (first user transaction).
    pub const FIRST: Self = Self(1);

    /// Construct a new TransactionId from a raw u64 value.
    #[inline]
    pub const fn new(id: u64) -> Self {
        Self(id)
    }

    /// Extract the raw u64 value from this TransactionId.
    #[inline]
    pub const fn as_u64(self) -> u64 {
        self.0
    }

    /// Check if this TransactionId represents a valid transaction (non-zero).
    #[inline]
    pub const fn is_valid(self) -> bool {
        self.0 > 0
    }

    /// Check if this is the initial TransactionId (no transaction).
    #[inline]
    pub const fn is_initial(self) -> bool {
        self.0 == 0
    }

    /// Get the next sequential TransactionId.
    #[inline]
    pub fn next(self) -> Option<Self> {
        self.0.checked_add(1).map(Self)
    }

    /// Calculate the number of transactions between two TransactionIds.
    ///
    /// Returns Some if other >= self, None if underflow would occur.
    #[inline]
    pub fn distance_to(self, other: Self) -> Option<u64> {
        other.0.checked_sub(self.0)
    }

    /// Convert to little-endian bytes.
    #[inline]
    pub const fn to_le_bytes(self) -> [u8; 8] {
        self.0.to_le_bytes()
    }

    /// Create TransactionId from little-endian bytes.
    #[inline]
    pub const fn from_le_bytes(bytes: [u8; 8]) -> Self {
        Self(u64::from_le_bytes(bytes))
    }
}

impl Debug for TransactionId {
    fn fmt(&self, f: &mut Formatter<'_>) -> fmt::Result {
        write!(f, "TransactionId({})", self.0)
    }
}

impl Display for TransactionId {
    fn fmt(&self, f: &mut Formatter<'_>) -> fmt::Result {
        write!(f, "txn {}", self.0)
    }
}

impl From<u64> for TransactionId {
    fn from(value: u64) -> Self {
        Self(value)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_page_id_special_values() {
        assert!(PageId::META_A.is_meta_page());
        assert!(PageId::META_B.is_meta_page());
        assert!(PageId::FIRST_DATA.is_data_page());
        assert!(!PageId::META_A.is_data_page());
    }

    #[test]
    fn test_page_id_next() {
        assert_eq!(PageId(5).next(), Some(PageId(6)));
        assert_eq!(PageId::new(u64::MAX).next(), None);
    }

    #[test]
    fn test_page_id_file_offset() {
        let page = PageId(10);
        assert_eq!(page.file_offset(4096), 40960);
        assert_eq!(page.file_offset(16384), 163840);
    }

    #[test]
    fn test_page_id_opposite_meta() {
        assert_eq!(PageId::META_A.opposite_meta_id(), Some(PageId::META_B));
        assert_eq!(PageId::META_B.opposite_meta_id(), Some(PageId::META_A));
        assert_eq!(PageId(5).opposite_meta_id(), None);
    }

    #[test]
    fn test_lsn_validity() {
        assert!(Lsn::INITIAL.is_initial());
        assert!(!Lsn::INITIAL.is_valid());
        assert!(Lsn::FIRST.is_valid());
        assert!(!Lsn::FIRST.is_initial());
    }

    #[test]
    fn test_lsn_next() {
        assert_eq!(Lsn(5).next(), Some(Lsn(6)));
        assert_eq!(Lsn::new(u64::MAX).next(), None);
    }

    #[test]
    fn test_lsn_distance() {
        assert_eq!(Lsn(10).distance_to(Lsn(15)), Some(5));
        assert_eq!(Lsn(10).distance_to(Lsn(10)), Some(0));
        assert_eq!(Lsn(15).distance_to(Lsn(10)), None);
    }

    #[test]
    fn test_lsn_bytes() {
        let lsn = Lsn(0x123456789ABCDEF0);
        let bytes = lsn.to_le_bytes();
        assert_eq!(Lsn::from_le_bytes(bytes), lsn);
    }

    #[test]
    fn test_txn_id_validity() {
        assert!(TransactionId::INITIAL.is_initial());
        assert!(!TransactionId::INITIAL.is_valid());
        assert!(TransactionId::FIRST.is_valid());
        assert!(!TransactionId::FIRST.is_initial());
    }

    #[test]
    fn test_txn_id_next() {
        assert_eq!(TransactionId(5).next(), Some(TransactionId(6)));
        assert_eq!(TransactionId::new(u64::MAX).next(), None);
    }

    #[test]
    fn test_txn_id_distance() {
        assert_eq!(TransactionId(10).distance_to(TransactionId(15)), Some(5));
        assert_eq!(TransactionId(10).distance_to(TransactionId(10)), Some(0));
        assert_eq!(TransactionId(15).distance_to(TransactionId(10)), None);
    }

    #[test]
    fn test_type_distinctness() {
        // Ensure types are not interchangeable
        let page_id = PageId(42);
        let lsn = Lsn(42);
        let txn_id = TransactionId(42);

        // Same numeric value but different types
        assert_eq!(page_id.as_u64(), lsn.as_u64());
        assert_eq!(lsn.as_u64(), txn_id.as_u64());

        // Ordering works within each type
        assert!(PageId(10) < PageId(20));
        assert!(Lsn(10) < Lsn(20));
        assert!(TransactionId(10) < TransactionId(20));
    }
}
