//! WAL record header and trailer structures
//!
//! Fixed-size structures that precede and follow every WAL record,
//! providing metadata, validation, and forward/backward scanning support.

use crate::checksum;
use crate::error::{Error, Result, ValidationError};
use byteorder::{ByteOrder, LittleEndian};

/// Magic number for WAL record header ("LOGR")
pub const RECORD_MAGIC: u32 = 0x4C4F4752;

/// Magic number for WAL record trailer ("RGOL" - "LOGR" reversed)
pub const TRAILER_MAGIC: u32 = 0x52474F4C;

/// WAL record format version (V0)
pub const RECORD_VERSION: u16 = 0;

/// Size of record header in bytes (V0 format)
pub const HEADER_SIZE: usize = 40;

/// Size of record trailer in bytes
pub const TRAILER_SIZE: usize = 12;

/// Maximum payload size for a single WAL record (16MB)
pub const MAX_PAYLOAD_SIZE: u32 = 16 * 1024 * 1024;

/// Record type enum
#[repr(u16)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RecordType {
    /// Transaction commit record containing mutations
    Commit = 0,
    /// Checkpoint marker record
    Checkpoint = 1,
    /// AI memory cartridge metadata record
    CartridgeMeta = 2,
}

impl RecordType {
    /// Convert from u16
    pub fn from_u16(val: u16) -> Option<Self> {
        match val {
            0 => Some(RecordType::Commit),
            1 => Some(RecordType::Checkpoint),
            2 => Some(RecordType::CartridgeMeta),
            _ => None,
        }
    }

    /// Convert to u16
    pub fn to_u16(self) -> u16 {
        self as u16
    }
}

/// Record flags
#[derive(Debug, Clone, Copy, Default)]
pub struct RecordFlags(u16);

impl RecordFlags {
    /// Empty flags
    pub const EMPTY: RecordFlags = RecordFlags(0);

    /// Create new flags
    pub const fn new(bits: u16) -> Self {
        RecordFlags(bits)
    }

    /// Check if payload contains inline values
    pub const fn has_inline_values(&self) -> bool {
        (self.0 & 0x0001) != 0
    }

    /// Set inline values flag
    pub fn with_inline_values(mut self) -> Self {
        self.0 |= 0x0001;
        self
    }

    /// Get raw flag bits
    pub const fn bits(&self) -> u16 {
        self.0
    }
}

/// WAL record header
///
/// Fixed-size header that precedes every WAL record. Contains metadata
/// for identifying, validating, and interpreting the record.
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct RecordHeader {
    /// Magic number for record identification (0x4C4F4752 = "LOGR")
    pub magic: u32,
    /// Record format version
    pub record_version: u16,
    /// Record type (commit=0, checkpoint=1, cartridge_meta=2)
    pub record_type: u16,
    /// Length of the header in bytes (40 for V0)
    pub header_len: u16,
    /// Bit flags for record attributes
    pub flags: u16,
    /// Transaction identifier
    pub txn_id: u64,
    /// LSN of the previous record
    pub prev_lsn: u64,
    /// Length of the record payload in bytes
    pub payload_len: u32,
    /// CRC32C checksum of the header fields
    pub header_crc32c: u32,
    /// CRC32C checksum of the payload data
    pub payload_crc32c: u32,
}

impl Default for RecordHeader {
    fn default() -> Self {
        RecordHeader {
            magic: RECORD_MAGIC,
            record_version: RECORD_VERSION,
            record_type: 0,
            header_len: HEADER_SIZE as u16,
            flags: 0,
            txn_id: 0,
            prev_lsn: 0,
            payload_len: 0,
            header_crc32c: 0,
            payload_crc32c: 0,
        }
    }
}

impl RecordHeader {
    /// Size of the header in bytes
    pub const fn size() -> usize {
        HEADER_SIZE
    }

    /// Create a new record header
    pub fn new(
        record_type: RecordType,
        flags: RecordFlags,
        txn_id: u64,
        prev_lsn: u64,
        payload_len: u32,
    ) -> Self {
        let mut header = RecordHeader {
            magic: RECORD_MAGIC,
            record_version: RECORD_VERSION,
            record_type: record_type.to_u16(),
            header_len: HEADER_SIZE as u16,
            flags: flags.bits(),
            txn_id,
            prev_lsn,
            payload_len,
            header_crc32c: 0,
            payload_crc32c: 0,
        };

        // Calculate header checksum (with checksum field zeroed)
        header.header_crc32c = header.calculate_header_checksum();

        header
    }

    /// Set the payload checksum and recalculate header checksum
    pub fn with_payload_checksum(mut self, payload_checksum: u32) -> Self {
        self.payload_crc32c = payload_checksum;
        // Recalculate header checksum with payload checksum set
        self.header_crc32c = self.calculate_header_checksum();
        self
    }

    /// Serialize header to bytes
    pub fn to_bytes(&self) -> [u8; HEADER_SIZE] {
        let mut buf = [0u8; HEADER_SIZE];

        LittleEndian::write_u32(&mut buf[0..4], self.magic);
        LittleEndian::write_u16(&mut buf[4..6], self.record_version);
        LittleEndian::write_u16(&mut buf[6..8], self.record_type);
        LittleEndian::write_u16(&mut buf[8..10], self.header_len);
        LittleEndian::write_u16(&mut buf[10..12], self.flags);
        LittleEndian::write_u64(&mut buf[12..20], self.txn_id);
        LittleEndian::write_u64(&mut buf[20..28], self.prev_lsn);
        LittleEndian::write_u32(&mut buf[28..32], self.payload_len);
        LittleEndian::write_u32(&mut buf[32..36], self.header_crc32c);
        LittleEndian::write_u32(&mut buf[36..40], self.payload_crc32c);

        buf
    }

    /// Deserialize header from bytes
    pub fn from_bytes(data: &[u8]) -> Result<Self> {
        if data.len() < HEADER_SIZE {
            return Err(Error::Validation(ValidationError::InvalidHeaderSize {
                expected: HEADER_SIZE,
                actual: data.len(),
            }));
        }

        let header = RecordHeader {
            magic: LittleEndian::read_u32(&data[0..4]),
            record_version: LittleEndian::read_u16(&data[4..6]),
            record_type: LittleEndian::read_u16(&data[6..8]),
            header_len: LittleEndian::read_u16(&data[8..10]),
            flags: LittleEndian::read_u16(&data[10..12]),
            txn_id: LittleEndian::read_u64(&data[12..20]),
            prev_lsn: LittleEndian::read_u64(&data[20..28]),
            payload_len: LittleEndian::read_u32(&data[28..32]),
            header_crc32c: LittleEndian::read_u32(&data[32..36]),
            payload_crc32c: LittleEndian::read_u32(&data[36..40]),
        };

        Ok(header)
    }

    /// Calculate header checksum (with checksum field zeroed)
    fn calculate_header_checksum(&self) -> u32 {
        let mut header_copy = *self;
        header_copy.header_crc32c = 0;

        let bytes = header_copy.to_bytes();
        checksum::checksum(&bytes)
    }

    /// Validate header checksum
    pub fn validate_header_checksum(&self) -> Result<()> {
        let calculated = self.calculate_header_checksum();

        if calculated != self.header_crc32c {
            return Err(Error::Validation(ValidationError::HeaderChecksumMismatch {
                expected: self.header_crc32c,
                actual: calculated,
            }));
        }

        Ok(())
    }

    /// Validate magic number
    pub fn validate_magic(&self) -> Result<()> {
        if self.magic != RECORD_MAGIC {
            return Err(Error::Validation(ValidationError::InvalidMagic {
                expected: RECORD_MAGIC,
                actual: self.magic,
            }));
        }

        Ok(())
    }

    /// Validate header version
    pub fn validate_version(&self) -> Result<()> {
        if self.record_version != RECORD_VERSION {
            return Err(Error::Validation(ValidationError::UnsupportedVersion {
                major: self.record_version as u16,
                minor: 0,
                patch: 0,
            }));
        }

        Ok(())
    }

    /// Validate record type
    pub fn validate_record_type(&self) -> Result<RecordType> {
        RecordType::from_u16(self.record_type).ok_or_else(|| {
            Error::Validation(ValidationError::Generic(format!(
                "Invalid record type: {}",
                self.record_type
            )))
        })
    }

    /// Validate payload length
    pub fn validate_payload_len(&self) -> Result<()> {
        if self.payload_len > MAX_PAYLOAD_SIZE {
            return Err(Error::Validation(ValidationError::PayloadLengthInvalid {
                len: self.payload_len,
                max: MAX_PAYLOAD_SIZE,
            }));
        }

        Ok(())
    }

    /// Validate all header fields
    pub fn validate(&self) -> Result<RecordType> {
        self.validate_magic()?;
        self.validate_version()?;
        self.validate_payload_len()?;
        self.validate_header_checksum()?;
        self.validate_record_type()
    }

    /// Get record type
    pub fn record_type_enum(&self) -> Option<RecordType> {
        RecordType::from_u16(self.record_type)
    }

    /// Get flags
    pub fn flags(&self) -> RecordFlags {
        RecordFlags::new(self.flags)
    }

    /// Calculate total record size (header + payload + trailer)
    pub fn total_size(&self) -> usize {
        HEADER_SIZE + self.payload_len as usize + TRAILER_SIZE
    }
}

/// WAL record trailer
///
/// Fixed-size trailer that follows every WAL record. Provides a second
/// validation point and allows backward scanning.
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct RecordTrailer {
    /// Second magic number (0x52474F4C = "RGOL")
    pub magic2: u32,
    /// Total length of entire record (header + payload + trailer)
    pub total_len: u32,
    /// CRC32C checksum of trailer fields
    pub trailer_crc32c: u32,
}

impl Default for RecordTrailer {
    fn default() -> Self {
        RecordTrailer {
            magic2: TRAILER_MAGIC,
            total_len: 0,
            trailer_crc32c: 0,
        }
    }
}

impl RecordTrailer {
    /// Size of the trailer in bytes
    pub const fn size() -> usize {
        TRAILER_SIZE
    }

    /// Create a new record trailer
    pub fn new(total_len: u32) -> Self {
        let mut trailer = RecordTrailer {
            magic2: TRAILER_MAGIC,
            total_len,
            trailer_crc32c: 0,
        };

        // Calculate trailer checksum (with checksum field zeroed)
        trailer.trailer_crc32c = trailer.calculate_checksum();

        trailer
    }

    /// Serialize trailer to bytes
    pub fn to_bytes(&self) -> [u8; TRAILER_SIZE] {
        let mut buf = [0u8; TRAILER_SIZE];

        LittleEndian::write_u32(&mut buf[0..4], self.magic2);
        LittleEndian::write_u32(&mut buf[4..8], self.total_len);
        LittleEndian::write_u32(&mut buf[8..12], self.trailer_crc32c);

        buf
    }

    /// Deserialize trailer from bytes
    pub fn from_bytes(data: &[u8]) -> Result<Self> {
        if data.len() < TRAILER_SIZE {
            return Err(Error::Validation(ValidationError::InvalidHeaderSize {
                expected: TRAILER_SIZE,
                actual: data.len(),
            }));
        }

        let trailer = RecordTrailer {
            magic2: LittleEndian::read_u32(&data[0..4]),
            total_len: LittleEndian::read_u32(&data[4..8]),
            trailer_crc32c: LittleEndian::read_u32(&data[8..12]),
        };

        Ok(trailer)
    }

    /// Calculate trailer checksum (with checksum field zeroed)
    fn calculate_checksum(&self) -> u32 {
        let mut trailer_copy = *self;
        trailer_copy.trailer_crc32c = 0;

        let bytes = trailer_copy.to_bytes();
        checksum::checksum(&bytes)
    }

    /// Validate trailer checksum
    pub fn validate_checksum(&self) -> Result<()> {
        let calculated = self.calculate_checksum();

        if calculated != self.trailer_crc32c {
            return Err(Error::Validation(ValidationError::ChecksumMismatch {
                expected: self.trailer_crc32c,
                actual: calculated,
            }));
        }

        Ok(())
    }

    /// Validate magic number
    pub fn validate_magic(&self) -> Result<()> {
        if self.magic2 != TRAILER_MAGIC {
            return Err(Error::Validation(ValidationError::InvalidMagic {
                expected: TRAILER_MAGIC,
                actual: self.magic2,
            }));
        }

        Ok(())
    }

    /// Validate total length matches expected
    pub fn validate_total_len(&self, expected: u32) -> Result<()> {
        if self.total_len != expected {
            return Err(Error::Validation(ValidationError::Generic(format!(
                "Trailer length mismatch: expected {}, got {}",
                expected, self.total_len
            ))));
        }

        Ok(())
    }

    /// Validate all trailer fields
    pub fn validate(&self, expected_total_len: u32) -> Result<()> {
        self.validate_magic()?;
        self.validate_checksum()?;
        self.validate_total_len(expected_total_len)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_record_header_serialization() {
        let header = RecordHeader::new(
            RecordType::Commit,
            RecordFlags::EMPTY,
            123,
            456,
            1024,
        );

        let bytes = header.to_bytes();
        let decoded = RecordHeader::from_bytes(&bytes).unwrap();

        assert_eq!(decoded.magic, header.magic);
        assert_eq!(decoded.record_version, header.record_version);
        assert_eq!(decoded.record_type, header.record_type);
        assert_eq!(decoded.txn_id, header.txn_id);
        assert_eq!(decoded.prev_lsn, header.prev_lsn);
        assert_eq!(decoded.payload_len, header.payload_len);
    }

    #[test]
    fn test_record_header_checksum_validation() {
        let header = RecordHeader::new(
            RecordType::Commit,
            RecordFlags::EMPTY,
            123,
            456,
            1024,
        );

        // Valid checksum should pass
        assert!(header.validate_header_checksum().is_ok());

        // Corrupted checksum should fail
        let mut corrupted = header;
        corrupted.header_crc32c = 0xDEADBEEF;
        assert!(corrupted.validate_header_checksum().is_err());
    }

    #[test]
    fn test_record_header_magic_validation() {
        let header = RecordHeader::new(
            RecordType::Commit,
            RecordFlags::EMPTY,
            123,
            456,
            1024,
        );

        // Valid magic should pass
        assert!(header.validate_magic().is_ok());

        // Invalid magic should fail
        let mut invalid = header;
        invalid.magic = 0xDEADBEEF;
        assert!(invalid.validate_magic().is_err());
    }

    #[test]
    fn test_record_type_conversion() {
        assert_eq!(RecordType::from_u16(0), Some(RecordType::Commit));
        assert_eq!(RecordType::from_u16(1), Some(RecordType::Checkpoint));
        assert_eq!(RecordType::from_u16(2), Some(RecordType::CartridgeMeta));
        assert_eq!(RecordType::from_u16(999), None);

        assert_eq!(RecordType::Commit.to_u16(), 0);
        assert_eq!(RecordType::Checkpoint.to_u16(), 1);
        assert_eq!(RecordType::CartridgeMeta.to_u16(), 2);
    }

    #[test]
    fn test_record_flags() {
        let flags = RecordFlags::EMPTY;
        assert!(!flags.has_inline_values());

        let flags = flags.with_inline_values();
        assert!(flags.has_inline_values());
    }

    #[test]
    fn test_record_trailer_serialization() {
        let trailer = RecordTrailer::new(2048);

        let bytes = trailer.to_bytes();
        let decoded = RecordTrailer::from_bytes(&bytes).unwrap();

        assert_eq!(decoded.magic2, trailer.magic2);
        assert_eq!(decoded.total_len, trailer.total_len);
    }

    #[test]
    fn test_record_trailer_checksum_validation() {
        let trailer = RecordTrailer::new(2048);

        // Valid checksum should pass
        assert!(trailer.validate_checksum().is_ok());

        // Corrupted checksum should fail
        let mut corrupted = trailer;
        corrupted.trailer_crc32c = 0xDEADBEEF;
        assert!(corrupted.validate_checksum().is_err());
    }

    #[test]
    fn test_record_trailer_magic_validation() {
        let trailer = RecordTrailer::new(2048);

        // Valid magic should pass
        assert!(trailer.validate_magic().is_ok());

        // Invalid magic should fail
        let mut invalid = trailer;
        invalid.magic2 = 0xDEADBEEF;
        assert!(invalid.validate_magic().is_err());
    }

    #[test]
    fn test_record_total_size() {
        let header = RecordHeader::new(
            RecordType::Commit,
            RecordFlags::EMPTY,
            0,
            0,
            1024,
        );

        // Total size = header (40) + payload (1024) + trailer (12)
        assert_eq!(header.total_size(), 1076);
    }
}
