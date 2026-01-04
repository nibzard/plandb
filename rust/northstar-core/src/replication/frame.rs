//! Message framing for replication protocol.
//!
//! Provides frame-level serialization with checksums and chunking support
//! for large messages like snapshots.

use crate::replication::{PROTOCOL_VERSION, MessageType};
use std::io::{self, Read, Write, Cursor};
use byteorder::{LittleEndian, ReadBytesExt, WriteBytesExt};

/// Frame header for wire format messages.
///
/// Layout (little-endian):
/// - magic: u32 (4 bytes) - Frame magic number for validation
/// - version: u16 (2 bytes) - Protocol version
/// - message_type: u16 (2 bytes) - Message type
/// - sequence: u64 (8 bytes) - Sequence number
/// - payload_length: u32 (4 bytes) - Payload size in bytes
/// - checksum: u32 (4 bytes) - CRC32C checksum of payload
///
/// Total header size: 24 bytes
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct FrameHeader {
    /// Magic number for frame validation.
    pub magic: u32,
    /// Protocol version.
    pub version: u16,
    /// Message type.
    pub message_type: MessageType,
    /// Sequence number.
    pub sequence: u64,
    /// Payload length in bytes.
    pub payload_length: u32,
    /// CRC32C checksum of payload.
    pub checksum: u32,
}

impl FrameHeader {
    /// Frame magic number for validation.
    pub const MAGIC: u32 = 0x4E535444; // "NSTD" in ASCII

    /// Size of frame header in bytes.
    pub const HEADER_SIZE: usize = 24;

    /// Create a new frame header.
    pub fn new(
        version: u16,
        message_type: MessageType,
        sequence: u64,
        payload_length: u32,
        checksum: u32,
    ) -> Self {
        Self {
            magic: Self::MAGIC,
            version,
            message_type,
            sequence,
            payload_length,
            checksum,
        }
    }

    /// Serialize header to bytes.
    pub fn to_bytes(&self) -> [u8; Self::HEADER_SIZE] {
        let mut buffer = [0u8; Self::HEADER_SIZE];
        let mut cursor = Cursor::new(&mut buffer[..]);

        cursor.write_u32::<LittleEndian>(self.magic).unwrap();
        cursor.write_u16::<LittleEndian>(self.version).unwrap();
        cursor.write_u16::<LittleEndian>(self.message_type.as_u16()).unwrap();
        cursor.write_u64::<LittleEndian>(self.sequence).unwrap();
        cursor.write_u32::<LittleEndian>(self.payload_length).unwrap();
        cursor.write_u32::<LittleEndian>(self.checksum).unwrap();

        buffer
    }

    /// Deserialize header from bytes.
    pub fn from_bytes(data: &[u8]) -> Result<Self, io::Error> {
        if data.len() < Self::HEADER_SIZE {
            return Err(io::Error::new(
                io::ErrorKind::UnexpectedEof,
                "Insufficient data for frame header",
            ));
        }

        let mut cursor = Cursor::new(data);
        let magic = cursor.read_u32::<LittleEndian>()?;
        let version = cursor.read_u16::<LittleEndian>()?;
        let message_type = cursor.read_u16::<LittleEndian>()?;
        let sequence = cursor.read_u64::<LittleEndian>()?;
        let payload_length = cursor.read_u32::<LittleEndian>()?;
        let checksum = cursor.read_u32::<LittleEndian>()?;

        // Validate magic number
        if magic != Self::MAGIC {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                format!("Invalid magic number: expected 0x{:08X}, got 0x{:08X}", Self::MAGIC, magic),
            ));
        }

        // Validate message type
        let msg_type = MessageType::from_u16(message_type).ok_or_else(|| {
            io::Error::new(io::ErrorKind::InvalidData, "Invalid message type")
        })?;

        Ok(Self {
            magic,
            version,
            message_type: msg_type,
            sequence,
            payload_length,
            checksum,
        })
    }

    /// Calculate the total frame size (header + payload).
    pub fn total_size(&self) -> usize {
        Self::HEADER_SIZE + self.payload_length as usize
    }

    /// Validate the protocol version.
    pub fn validate_version(&self) -> Result<(), io::Error> {
        if self.version != PROTOCOL_VERSION {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                format!(
                    "Protocol version mismatch: expected {}, got {}",
                    PROTOCOL_VERSION, self.version
                ),
            ));
        }
        Ok(())
    }
}

/// Frame writer for serializing framed messages.
pub struct FrameWriter<W: Write> {
    writer: W,
}

impl<W: Write> FrameWriter<W> {
    /// Create a new frame writer.
    pub fn new(writer: W) -> Self {
        Self { writer }
    }

    /// Write a complete frame (header + payload).
    pub fn write_frame(&mut self, header: &FrameHeader, payload: &[u8]) -> Result<(), io::Error> {
        // Validate payload length matches header
        if payload.len() != header.payload_length as usize {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                format!(
                    "Payload length mismatch: header says {}, actual {}",
                    header.payload_length,
                    payload.len()
                ),
            ));
        }

        // Validate checksum
        let calculated_checksum = crc32c::crc32c(payload);
        if calculated_checksum != header.checksum {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                format!(
                    "Checksum mismatch: expected 0x{:08X}, calculated 0x{:08X}",
                    header.checksum, calculated_checksum
                ),
            ));
        }

        // Write header
        self.writer.write_all(&header.to_bytes())?;

        // Write payload
        self.writer.write_all(payload)?;

        Ok(())
    }

    /// Flush the underlying writer.
    pub fn flush(&mut self) -> Result<(), io::Error> {
        self.writer.flush()
    }

    /// Consume the writer and return the inner writer.
    pub fn into_inner(self) -> W {
        self.writer
    }
}

/// Frame reader for deserializing framed messages.
pub struct FrameReader<R: Read> {
    reader: R,
    buffer: Vec<u8>,
}

impl<R: Read> FrameReader<R> {
    /// Create a new frame reader.
    pub fn new(reader: R) -> Self {
        Self {
            reader,
            buffer: Vec::new(),
        }
    }

    /// Read a complete frame (header + payload).
    ///
    /// Returns the header and payload bytes.
    pub fn read_frame(&mut self) -> Result<(FrameHeader, Vec<u8>), io::Error> {
        // Read header
        let mut header_bytes = [0u8; FrameHeader::HEADER_SIZE];
        self.reader.read_exact(&mut header_bytes)?;
        let header = FrameHeader::from_bytes(&header_bytes)?;

        // Validate version
        header.validate_version()?;

        // Read payload
        let payload_length = header.payload_length as usize;

        // Protect against unreasonably large payloads
        const MAX_PAYLOAD_SIZE: usize = 100 * 1024 * 1024; // 100MB
        if payload_length > MAX_PAYLOAD_SIZE {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                format!("Payload too large: {} bytes (max {})", payload_length, MAX_PAYLOAD_SIZE),
            ));
        }

        let mut payload = vec![0u8; payload_length];
        if payload_length > 0 {
            self.reader.read_exact(&mut payload)?;
        }

        // Validate checksum
        let calculated_checksum = crc32c::crc32c(&payload);
        if calculated_checksum != header.checksum {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                format!(
                    "Checksum validation failed: expected 0x{:08X}, calculated 0x{:08X}",
                    header.checksum, calculated_checksum
                ),
            ));
        }

        Ok((header, payload))
    }

    /// Read remaining data into the internal buffer.
    ///
    /// Useful for handling partial reads.
    pub fn read_into_buffer(&mut self, size: usize) -> Result<(), io::Error> {
        self.buffer.resize(size, 0);
        self.reader.read_exact(&mut self.buffer)?;
        Ok(())
    }

    /// Get a reference to the internal buffer.
    pub fn buffer(&self) -> &[u8] {
        &self.buffer
    }

    /// Clear the internal buffer.
    pub fn clear_buffer(&mut self) {
        self.buffer.clear();
    }

    /// Consume the reader and return the inner reader.
    pub fn into_inner(self) -> R {
        self.reader
    }
}

/// Maximum chunk size for snapshot messages (1MB).
const SNAPSHOT_CHUNK_SIZE: usize = 1024 * 1024;

/// Chunk large payloads into smaller frames.
///
/// Useful for sending large snapshots in multiple frames.
pub fn chunk_payload(payload: &[u8], message_type: MessageType, sequence: u64) -> Vec<(FrameHeader, Vec<u8>)> {
    let mut frames = Vec::new();
    let total_chunks = (payload.len() + SNAPSHOT_CHUNK_SIZE - 1) / SNAPSHOT_CHUNK_SIZE;

    for (chunk_index, chunk) in payload.chunks(SNAPSHOT_CHUNK_SIZE).enumerate() {
        let checksum = crc32c::crc32c(chunk);
        let header = FrameHeader::new(
            PROTOCOL_VERSION,
            message_type,
            sequence + chunk_index as u64,
            chunk.len() as u32,
            checksum,
        );
        frames.push((header, chunk.to_vec()));
    }

    frames
}

/// Reassemble chunked payload from multiple frames.
///
/// Returns the reassembled payload and total number of chunks.
pub fn reassemble_payload(frames: Vec<(FrameHeader, Vec<u8>)>) -> Result<(Vec<u8>, usize), io::Error> {
    let chunk_count = frames.len();

    if frames.is_empty() {
        return Ok((vec![], 0));
    }

    // Verify all frames have the same message type
    let message_type = frames[0].0.message_type;
    if !frames.iter().all(|f| f.0.message_type == message_type) {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "Message type mismatch in chunked frames",
        ));
    }

    // Calculate total size
    let total_size: usize = frames.iter().map(|f| f.1.len()).sum();
    let mut payload = Vec::with_capacity(total_size);

    // Concatenate all payloads
    for (_, chunk) in frames {
        payload.extend_from_slice(&chunk);
    }

    Ok((payload, chunk_count))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_frame_header_constants() {
        assert_eq!(FrameHeader::MAGIC, 0x4E535444);
        assert_eq!(FrameHeader::HEADER_SIZE, 24);
    }

    #[test]
    fn test_frame_header_new() {
        let header = FrameHeader::new(
            1,
            MessageType::Heartbeat,
            100,
            0,
            0,
        );

        assert_eq!(header.magic, FrameHeader::MAGIC);
        assert_eq!(header.version, 1);
        assert_eq!(header.message_type, MessageType::Heartbeat);
        assert_eq!(header.sequence, 100);
        assert_eq!(header.payload_length, 0);
        assert_eq!(header.checksum, 0);
    }

    #[test]
    fn test_frame_header_to_bytes() {
        let header = FrameHeader::new(
            1,
            MessageType::CommitRecord,
            200,
            1024,
            0x12345678,
        );

        let bytes = header.to_bytes();
        assert_eq!(bytes.len(), FrameHeader::HEADER_SIZE);
    }

    #[test]
    fn test_frame_header_from_bytes() {
        let header = FrameHeader::new(
            1,
            MessageType::Snapshot,
            300,
            2048,
            0xABCDEF00,
        );

        let bytes = header.to_bytes();
        let deserialized = FrameHeader::from_bytes(&bytes).unwrap();

        assert_eq!(deserialized.magic, header.magic);
        assert_eq!(deserialized.version, header.version);
        assert_eq!(deserialized.message_type, header.message_type);
        assert_eq!(deserialized.sequence, header.sequence);
        assert_eq!(deserialized.payload_length, header.payload_length);
        assert_eq!(deserialized.checksum, header.checksum);
    }

    #[test]
    fn test_frame_header_invalid_magic() {
        let mut bytes = [0u8; FrameHeader::HEADER_SIZE];
        bytes[0] = 0xFF; // Invalid magic
        bytes[1] = 0xFF;
        bytes[2] = 0xFF;
        bytes[3] = 0xFF;

        let result = FrameHeader::from_bytes(&bytes);
        assert!(result.is_err());
    }

    #[test]
    fn test_frame_header_insufficient_data() {
        let bytes = [0u8; 10]; // Too short

        let result = FrameHeader::from_bytes(&bytes);
        assert!(result.is_err());
    }

    #[test]
    fn test_frame_header_total_size() {
        let header = FrameHeader::new(
            1,
            MessageType::CommitRecord,
            100,
            512,
            0,
        );

        assert_eq!(header.total_size(), FrameHeader::HEADER_SIZE + 512);
    }

    #[test]
    fn test_frame_header_validate_version() {
        let valid_header = FrameHeader::new(
            PROTOCOL_VERSION,
            MessageType::Heartbeat,
            100,
            0,
            0,
        );
        assert!(valid_header.validate_version().is_ok());

        let invalid_header = FrameHeader::new(
            PROTOCOL_VERSION + 1,
            MessageType::Heartbeat,
            100,
            0,
            0,
        );
        assert!(invalid_header.validate_version().is_err());
    }

    #[test]
    fn test_frame_writer_write_frame() {
        let payload = b"Hello, world!";
        let checksum = crc32c::crc32c(payload);
        let header = FrameHeader::new(
            1,
            MessageType::CommitRecord,
            100,
            payload.len() as u32,
            checksum,
        );

        let mut buffer = Vec::new();
        {
            let mut writer = FrameWriter::new(&mut buffer);
            writer.write_frame(&header, payload).unwrap();
        }

        assert!(!buffer.is_empty());
        assert!(buffer.len() >= FrameHeader::HEADER_SIZE + payload.len());
    }

    #[test]
    fn test_frame_writer_payload_length_mismatch() {
        let payload = b"test payload";
        let header = FrameHeader::new(
            1,
            MessageType::CommitRecord,
            100,
            999, // Wrong length
            0,
        );

        let mut buffer = Vec::new();
        let mut writer = FrameWriter::new(&mut buffer);
        let result = writer.write_frame(&header, payload);

        assert!(result.is_err());
    }

    #[test]
    fn test_frame_reader_read_frame() {
        let payload = b"test payload data";
        let checksum = crc32c::crc32c(payload);
        let header = FrameHeader::new(
            1,
            MessageType::CommitRecord,
            100,
            payload.len() as u32,
            checksum,
        );

        let mut buffer = Vec::new();
        {
            let mut writer = FrameWriter::new(&mut buffer);
            writer.write_frame(&header, payload).unwrap();
        }

        let mut reader = FrameReader::new(buffer.as_slice());
        let (read_header, read_payload) = reader.read_frame().unwrap();

        assert_eq!(read_header.version, header.version);
        assert_eq!(read_header.message_type, header.message_type);
        assert_eq!(read_header.sequence, header.sequence);
        assert_eq!(read_payload, payload);
    }

    #[test]
    fn test_frame_reader_checksum_validation() {
        let payload = b"test payload";
        let header = FrameHeader::new(
            1,
            MessageType::CommitRecord,
            100,
            payload.len() as u32,
            0xADBADBADu32, // Wrong checksum
        );

        let mut buffer = Vec::new();
        buffer.extend_from_slice(&header.to_bytes());
        buffer.extend_from_slice(payload);

        let mut reader = FrameReader::new(buffer.as_slice());
        let result = reader.read_frame();

        assert!(result.is_err());
    }

    #[test]
    fn test_chunk_payload_small() {
        let payload = b"small payload";
        let frames = chunk_payload(payload, MessageType::Snapshot, 100);

        assert_eq!(frames.len(), 1);
        assert_eq!(frames[0].1, payload);
    }

    #[test]
    fn test_chunk_payload_large() {
        // Create a 2MB payload
        let payload = vec![0xABu8; 2 * 1024 * 1024];
        let frames = chunk_payload(&payload, MessageType::Snapshot, 100);

        // Should be split into 2 chunks
        assert_eq!(frames.len(), 2);
        assert!(frames[0].1.len() <= SNAPSHOT_CHUNK_SIZE);
        assert!(frames[1].1.len() <= SNAPSHOT_CHUNK_SIZE);
    }

    #[test]
    fn test_reassemble_payload() {
        let payload = b"complete payload";
        let frames = chunk_payload(payload, MessageType::Snapshot, 100);

        let (reassembled, chunk_count) = reassemble_payload(frames).unwrap();

        assert_eq!(reassembled, payload);
        assert_eq!(chunk_count, 1);
    }

    #[test]
    fn test_reassemble_chunked_payload() {
        let payload = vec![0xCDu8; 2 * 1024 * 1024];
        let frames = chunk_payload(&payload, MessageType::Snapshot, 100);

        let (reassembled, chunk_count) = reassemble_payload(frames).unwrap();

        assert_eq!(reassembled, payload);
        assert_eq!(chunk_count, 2);
    }

    #[test]
    fn test_reassemble_empty_frames() {
        let frames = vec![];
        let (payload, count) = reassemble_payload(frames).unwrap();

        assert!(payload.is_empty());
        assert_eq!(count, 0);
    }

    #[test]
    fn test_reassemble_mismatched_types() {
        let frame1 = (FrameHeader::new(1, MessageType::Snapshot, 100, 10, 0), vec![1u8; 10]);
        let frame2 = (FrameHeader::new(1, MessageType::CommitRecord, 101, 10, 0), vec![2u8; 10]);

        let frames = vec![frame1, frame2];
        let result = reassemble_payload(frames);

        assert!(result.is_err());
    }
}
