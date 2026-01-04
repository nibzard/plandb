//! Main WAL (Write-Ahead Log) implementation
//!
//! Provides append-only logging for transaction durability and crash recovery.

use super::config::{WalConfig, WalState};
use super::header::{RecordHeader, RecordTrailer, RecordType, HEADER_SIZE, TRAILER_SIZE};
use super::record::CommitRecord;
use crate::checksum;
use crate::error::{Error, IoError, Result, ValidationError};
use crate::types::Lsn;
use std::fs::File;
use std::io::{Read, Seek, SeekFrom, Write};
use std::mem::ManuallyDrop;
use std::path::Path;

/// Iterator over commit records in the WAL
pub struct WalReplayIterator {
    /// WAL file being replayed
    file: File,
    /// Current file position
    file_pos: u64,
    /// Size of the WAL file
    file_size: u64,
    /// Current LSN
    current_lsn: u64,
    /// Whether iteration is complete
    done: bool,
}

impl WalReplayIterator {
    /// Create a new WAL replay iterator
    fn new(mut file: File, file_size: u64) -> Result<Self> {
        // Start from beginning of file
        file.seek(SeekFrom::Start(0))
            .map_err(|e| Error::Io(IoError::from(e)))?;

        Ok(Self {
            file,
            file_pos: 0,
            file_size,
            current_lsn: 0,
            done: false,
        })
    }

    /// Get current LSN
    pub fn current_lsn(&self) -> u64 {
        self.current_lsn
    }

    /// Attempt to resync to next valid record after corruption
    ///
    /// Seeks forward by the specified byte offset to find a potential
    /// valid record boundary.
    pub fn resync(&mut self, offset: u64) -> Result<()> {
        let new_pos = self.file_pos + offset;

        if new_pos >= self.file_size {
            self.done = true;
            return Ok(());
        }

        self.file.seek(SeekFrom::Start(new_pos))
            .map_err(|e| Error::Io(IoError::from(e)))?;
        self.file_pos = new_pos;

        Ok(())
    }
}

impl Iterator for WalReplayIterator {
    type Item = Result<CommitRecord>;

    fn next(&mut self) -> Option<Self::Item> {
        if self.done {
            return None;
        }

        // Check if we've reached EOF
        if self.file_pos >= self.file_size {
            self.done = true;
            return None;
        }

        // Try to read next commit record
        match Self::read_next_commit(&mut self.file, self.file_pos, self.file_size) {
            Ok(Some((record, record_size))) => {
                self.current_lsn += 1;
                self.file_pos += record_size;
                Some(Ok(record))
            }
            Ok(None) => {
                // EOF or incomplete record - stop iteration
                self.done = true;
                None
            }
            Err(Error::Validation(_)) => {
                // Corruption detected - stop iteration
                // The caller can use resync() if they want to continue
                self.done = true;
                None
            }
            Err(e) => Some(Err(e)),
        }
    }
}

impl WalReplayIterator {
    /// Read the next commit record from the WAL
    ///
    /// Returns Ok(Some((record, size))) on success,
    /// Ok(None) on EOF or incomplete record,
    /// Err on corruption that can't be handled.
    fn read_next_commit(
        file: &mut File,
        file_pos: u64,
        file_size: u64,
    ) -> Result<Option<(CommitRecord, u64)>> {
        // Check if we have enough bytes for header
        if file_pos + HEADER_SIZE as u64 > file_size {
            // EOF - no more records
            return Ok(None);
        }

        // Read header
        file.seek(SeekFrom::Start(file_pos))
            .map_err(|e| Error::Io(IoError::from(e)))?;

        let mut header_buf = [0u8; HEADER_SIZE];
        if let Err(e) = file.read_exact(&mut header_buf) {
            return Err(Error::Io(IoError::from(e)));
        }

        let header = match RecordHeader::from_bytes(&header_buf) {
            Ok(h) => h,
            Err(_) => {
                // Invalid header - likely corruption, signal to resync
                return Ok(None);
            }
        };

        // Validate header
        if header.validate().is_err() {
            // Invalid header - signal to resync
            return Ok(None);
        }

        // Check record type
        let record_type = match RecordType::from_u16(header.record_type) {
            Some(rt) => rt,
            None => {
                // Unknown record type - skip
                return Ok(None);
            }
        };

        if record_type != RecordType::Commit {
            // Skip non-commit records (for future extensibility)
            let payload_len = header.payload_len as usize;
            let record_size = HEADER_SIZE + payload_len + TRAILER_SIZE;

            if file_pos + record_size as u64 > file_size {
                return Ok(None);
            }

            return Ok(None);
        }

        let payload_len = header.payload_len as usize;
        let record_size = HEADER_SIZE + payload_len + TRAILER_SIZE;

        // Check if complete record fits in file
        if file_pos + record_size as u64 > file_size {
            // Incomplete record at end - stop
            return Ok(None);
        }

        // Read payload
        let mut payload = vec![0u8; payload_len];
        file.read_exact(&mut payload)
            .map_err(|e| Error::Io(IoError::from(e)))?;

        // Validate payload checksum
        let calculated_checksum = checksum::checksum(&payload);
        if calculated_checksum != header.payload_crc32c {
            return Err(Error::Validation(ValidationError::ChecksumMismatch {
                expected: header.payload_crc32c,
                actual: calculated_checksum,
            }));
        }

        // Read and validate trailer
        let trailer_offset = file_pos + HEADER_SIZE as u64 + payload_len as u64;
        file.seek(SeekFrom::Start(trailer_offset))
            .map_err(|e| Error::Io(IoError::from(e)))?;

        let mut trailer_buf = [0u8; TRAILER_SIZE];
        file.read_exact(&mut trailer_buf)
            .map_err(|e| Error::Io(IoError::from(e)))?;

        let trailer = match RecordTrailer::from_bytes(&trailer_buf) {
            Ok(t) => t,
            Err(_) => {
                // Invalid trailer - corruption
                return Ok(None);
            }
        };

        if trailer.validate(record_size as u32).is_err() {
            return Ok(None);
        }

        // Deserialize commit record from payload
        let commit_record = match CommitRecord::deserialize_payload(header.txn_id, &payload) {
            Ok(record) => record,
            Err(_) => {
                // Failed to deserialize - corruption
                return Ok(None);
            }
        };

        Ok(Some((commit_record, record_size as u64)))
    }
}

/// Default WAL buffer size (64KB)
const DEFAULT_BUFFER_SIZE: usize = 64 * 1024;

/// WAL (Write-Ahead Log) - main struct
///
/// Manages an append-only log file that stores all transaction modifications
/// before they are applied to the database. Provides atomicity and durability
/// guarantees through write-ahead logging.
pub struct Wal {
    /// File handle for the WAL log file
    file: File,

    /// Current LSN (most recently appended record)
    current_lsn: u64,

    /// Internal write buffer for batched I/O
    buffer: Vec<u8>,

    /// Current write position within the buffer
    buffer_pos: usize,

    /// Flag indicating whether buffered data needs sync
    sync_needed: bool,

    /// Current file position for appending new data
    file_pos: u64,

    /// WAL state
    state: WalState,

    /// Configuration
    config: WalConfig,
}

impl Wal {
    /// Open an existing WAL file
    ///
    /// Opens the WAL file, scans to validate all records and find the current LSN,
    /// and positions the WAL for continued operation or crash recovery.
    pub fn open<P: AsRef<Path>>(path: P) -> Result<Self> {
        let path = path.as_ref();

        // Open file with read-write access
        let mut file = File::options()
            .read(true)
            .write(true)
            .open(path)
            .map_err(|e| {
                if e.kind() == std::io::ErrorKind::NotFound {
                    Error::Io(IoError::FileNotFound {
                        path: path.to_string_lossy().to_string(),
                    })
                } else {
                    Error::Io(IoError::from(e))
                }
            })?;

        // Get file size
        let file_size = file.metadata().map_err(|e| Error::Io(IoError::from(e)))?.len();

        // Scan for highest LSN
        let (current_lsn, end_pos) = if file_size == 0 {
            // Empty WAL
            (0, 0)
        } else {
            Self::scan_highest_lsn(&mut file, file_size)?
        };

        // Allocate buffer
        let buffer = vec![0u8; DEFAULT_BUFFER_SIZE];

        // Create WAL instance
        let mut wal = Wal {
            file,
            current_lsn,
            buffer,
            buffer_pos: 0,
            sync_needed: false,
            file_pos: end_pos,
            state: WalState::Open,
            config: WalConfig::default(),
        };

        // Position file pointer at end
        wal.file.seek(SeekFrom::Start(end_pos))
            .map_err(|e| Error::Io(IoError::from(e)))?;

        Ok(wal)
    }

    /// Create a new WAL file
    ///
    /// Creates a new empty WAL file, truncating if it exists.
    pub fn create<P: AsRef<Path>>(path: P) -> Result<Self> {
        let path = path.as_ref();

        // Create/truncate file
        let file = File::create(path).map_err(|e| Error::Io(IoError::from(e)))?;

        // Allocate buffer
        let buffer = vec![0u8; DEFAULT_BUFFER_SIZE];

        Ok(Wal {
            file,
            current_lsn: 0,
            buffer,
            buffer_pos: 0,
            sync_needed: false,
            file_pos: 0,
            state: WalState::Open,
            config: WalConfig::default(),
        })
    }

    /// Close the WAL and release all resources
    ///
    /// Flushes any buffered data and closes the file handle.
    pub fn close(&mut self) -> Result<()> {
        if self.state != WalState::Open {
            return Ok(()); // Already closed
        }

        // Flush buffer
        if self.buffer_pos > 0 {
            self.flush_buffer()?;
        }

        // Sync to disk
        let _ = self.file.sync_all();

        // Close file handle
        let _ = self.file.flush();

        // Mark as closed
        self.state = WalState::Closed;

        Ok(())
    }

    /// Get the current LSN (most recently appended record)
    pub fn current_lsn(&self) -> u64 {
        self.current_lsn
    }

    /// Get the current file position
    pub fn file_pos(&self) -> u64 {
        self.file_pos
    }

    /// Get the WAL state
    pub fn state(&self) -> WalState {
        self.state
    }

    /// Check if sync is needed
    pub fn sync_needed(&self) -> bool {
        self.sync_needed
    }

    /// Sync all buffered writes to stable storage
    pub fn sync(&mut self) -> Result<()> {
        // Flush buffer first
        if self.buffer_pos > 0 {
            self.flush_buffer()?;
        }

        // Sync file
        self.file.sync_all()
            .map_err(|e| Error::Io(IoError::from(e)))?;

        self.sync_needed = false;

        Ok(())
    }

    /// Append a commit record to the WAL
    pub fn append_commit_record(&mut self, record: &CommitRecord) -> Result<Lsn> {
        self.ensure_open()?;

        // Serialize the record
        let payload = record.serialize_payload();
        let payload_len = payload.len() as u32;

        // Calculate payload checksum
        let payload_checksum = checksum::checksum(&payload);

        // Create header with payload checksum
        let header = RecordHeader::new(
            RecordType::Commit,
            super::header::RecordFlags::EMPTY,
            record.txn_id(),
            self.current_lsn,
            payload_len,
        ).with_payload_checksum(payload_checksum);

        // Calculate total record size
        let total_size = HEADER_SIZE + payload_len as usize + TRAILER_SIZE;

        // Check if we need to flush buffer first
        if self.buffer_pos + total_size > self.buffer.len() {
            self.flush_buffer()?;

            // If still too large for buffer, write directly
            if total_size > self.buffer.len() {
                return self.write_large_record(&header, &payload);
            }
        }

        // Write to buffer
        self.write_record_to_buffer(&header, &payload)?;

        // Update LSN
        self.current_lsn += 1;

        Ok(Lsn::new(self.current_lsn))
    }

    /// Scan WAL to find the highest LSN and validate all records
    fn scan_highest_lsn(file: &mut File, file_size: u64) -> Result<(u64, u64)> {
        let mut file_pos = 0u64;
        let mut current_lsn = 0u64;

        while file_pos < file_size {
            // Read header
            let mut header_buf = [0u8; HEADER_SIZE];
            if file_pos + HEADER_SIZE as u64 > file_size {
                // Incomplete header at end - stop here
                break;
            }

            file.seek(SeekFrom::Start(file_pos))
                .map_err(|e| Error::Io(IoError::from(e)))?;
            file.read_exact(&mut header_buf)
                .map_err(|e| Error::Io(IoError::from(e)))?;

            let header = RecordHeader::from_bytes(&header_buf)?;

            // Validate header
            header.validate()?;

            let payload_len = header.payload_len as usize;
            let record_size = HEADER_SIZE + payload_len + TRAILER_SIZE;

            // Check if record fits in file
            if file_pos + record_size as u64 > file_size {
                // Incomplete record - stop here
                break;
            }

            // Read and validate payload
            let mut payload = vec![0u8; payload_len];
            file.read_exact(&mut payload)
                .map_err(|e| Error::Io(IoError::from(e)))?;

            // Validate payload checksum
            let calculated_checksum = checksum::checksum(&payload);
            if calculated_checksum != header.payload_crc32c {
                return Err(Error::Validation(ValidationError::ChecksumMismatch {
                    expected: header.payload_crc32c,
                    actual: calculated_checksum,
                }));
            }

            // Read trailer
            let trailer_offset = file_pos + HEADER_SIZE as u64 + payload_len as u64;
            file.seek(SeekFrom::Start(trailer_offset))
                .map_err(|e| Error::Io(IoError::from(e)))?;

            let mut trailer_buf = [0u8; TRAILER_SIZE];
            file.read_exact(&mut trailer_buf)
                .map_err(|e| Error::Io(IoError::from(e)))?;

            let trailer = RecordTrailer::from_bytes(&trailer_buf)?;
            trailer.validate((record_size) as u32)?;

            // Record is valid
            current_lsn += 1;
            file_pos += record_size as u64;
        }

        Ok((current_lsn, file_pos))
    }

    /// Flush the internal buffer to disk
    fn flush_buffer(&mut self) -> Result<()> {
        if self.buffer_pos == 0 {
            return Ok(());
        }

        self.file.write_all(&self.buffer[..self.buffer_pos])
            .map_err(|e| Error::Io(IoError::from(e)))?;

        self.file_pos += self.buffer_pos as u64;
        self.buffer_pos = 0;
        self.sync_needed = true;

        Ok(())
    }

    /// Write a record to the buffer
    fn write_record_to_buffer(&mut self, header: &RecordHeader, payload: &[u8]) -> Result<()> {
        // Write header
        let header_bytes = header.to_bytes();
        self.buffer[self.buffer_pos..self.buffer_pos + HEADER_SIZE]
            .copy_from_slice(&header_bytes);
        self.buffer_pos += HEADER_SIZE;

        // Write payload
        self.buffer[self.buffer_pos..self.buffer_pos + payload.len()]
            .copy_from_slice(payload);
        self.buffer_pos += payload.len();

        // Create and write trailer
        let total_len = (HEADER_SIZE + payload.len() + TRAILER_SIZE) as u32;
        let trailer = RecordTrailer::new(total_len);
        let trailer_bytes = trailer.to_bytes();
        self.buffer[self.buffer_pos..self.buffer_pos + TRAILER_SIZE]
            .copy_from_slice(&trailer_bytes);
        self.buffer_pos += TRAILER_SIZE;

        self.sync_needed = true;

        Ok(())
    }

    /// Write a large record directly to file (bypasses buffer)
    fn write_large_record(&mut self, header: &RecordHeader, payload: &[u8]) -> Result<Lsn> {
        // Ensure buffer is flushed first
        self.flush_buffer()?;

        // Write header
        self.file.write_all(&header.to_bytes())
            .map_err(|e| Error::Io(IoError::from(e)))?;

        // Write payload
        self.file.write_all(payload)
            .map_err(|e| Error::Io(IoError::from(e)))?;

        // Write trailer
        let total_len = (HEADER_SIZE + payload.len() + TRAILER_SIZE) as u32;
        let trailer = RecordTrailer::new(total_len);
        self.file.write_all(&trailer.to_bytes())
            .map_err(|e| Error::Io(IoError::from(e)))?;

        self.file_pos += HEADER_SIZE as u64 + payload.len() as u64 + TRAILER_SIZE as u64;
        self.sync_needed = true;

        Ok(Lsn::new(self.current_lsn + 1))
    }

    /// Ensure WAL is in open state
    fn ensure_open(&self) -> Result<()> {
        if self.state != WalState::Open {
            return Err(Error::Storage(crate::error::StorageError::Wal(
                "WAL is not open".to_string(),
            )));
        }
        Ok(())
    }

    /// Create a replay iterator for this WAL
    ///
    /// Returns an iterator that yields commit records from the WAL in LSN order.
    /// The iterator takes ownership of the WAL file handle, so the WAL cannot
    /// be used for writing after calling this method.
    ///
    /// This is the primary API for crash recovery and WAL replay.
    ///
    /// # Returns
    /// Iterator over commit records in the WAL
    ///
    /// # Errors
    /// - Returns error if WAL file cannot be reopened for reading
    pub fn replay(mut self) -> Result<WalReplayIterator> {
        // Flush any buffered data first
        if self.buffer_pos > 0 {
            self.flush_buffer()?;
        }

        // Get file size before consuming self
        let file_size = self.file.metadata()
            .map_err(|e| Error::Io(IoError::from(e)))?
            .len();

        // Prevent Drop from closing the file - we're transferring ownership
        let mut this = ManuallyDrop::new(self);

        // Extract the file handle
        let file = unsafe {
            // SAFETY: We're taking ownership of the file and preventing
            // the Drop impl from running. The file will be owned by
            // WalReplayIterator which will properly close it.
            std::ptr::read(&this.file)
        };

        // Create iterator
        WalReplayIterator::new(file, file_size)
    }

    /// Create a replay iterator without consuming the WAL
    ///
    /// This method clones the file handle to create an iterator for reading
    /// while still allowing writes to the WAL. This is useful for recovery
    /// scenarios where you need to keep the WAL open.
    ///
    /// Note: This creates a second file handle, which has overhead.
    /// Use `replay()` instead if you don't need to keep the WAL open.
    ///
    /// # Returns
    /// Iterator over commit records in the WAL
    ///
    /// # Errors
    /// - Returns error if WAL file handle cannot be cloned
    /// - Returns error if file metadata cannot be read
    pub fn replay_ref(&self) -> Result<WalReplayIterator> {
        // Flush any buffered data first
        if self.buffer_pos > 0 {
            return Err(Error::Storage(crate::error::StorageError::Wal(
                "WAL has unflushed data. Call sync() before replay_ref().".to_string(),
            )));
        }

        // Clone the file handle
        let file_clone = self.file.try_clone()
            .map_err(|e| Error::Io(IoError::from(e)))?;

        // Get file size
        let file_size = self.file.metadata()
            .map_err(|e| Error::Io(IoError::from(e)))?
            .len();

        // Create iterator from cloned handle
        WalReplayIterator::new(file_clone, file_size)
    }
}

impl Drop for Wal {
    fn drop(&mut self) {
        // Best-effort close on drop
        let _ = self.close();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use tempfile::tempdir;

    #[test]
    fn test_create_wal() {
        let dir = tempdir().unwrap();
        let wal_path = dir.path().join("test.wal");

        let wal = Wal::create(&wal_path).unwrap();

        assert_eq!(wal.current_lsn(), 0);
        assert_eq!(wal.file_pos(), 0);
        assert_eq!(wal.state(), WalState::Open);
        assert!(!wal.sync_needed());
    }

    #[test]
    fn test_create_creates_file() {
        let dir = tempdir().unwrap();
        let wal_path = dir.path().join("test.wal");

        Wal::create(&wal_path).unwrap();

        assert!(wal_path.exists());
    }

    #[test]
    fn test_open_empty_wal() {
        let dir = tempdir().unwrap();
        let wal_path = dir.path().join("test.wal");

        // Create empty WAL
        Wal::create(&wal_path).unwrap().close().unwrap();

        // Open empty WAL
        let wal = Wal::open(&wal_path).unwrap();

        assert_eq!(wal.current_lsn(), 0);
        assert_eq!(wal.file_pos(), 0);
    }

    #[test]
    fn test_open_nonexistent_fails() {
        let dir = tempdir().unwrap();
        let wal_path = dir.path().join("nonexistent.wal");

        let result = Wal::open(&wal_path);

        assert!(result.is_err());
    }

    #[test]
    fn test_close_wal() {
        let dir = tempdir().unwrap();
        let wal_path = dir.path().join("test.wal");

        let mut wal = Wal::create(&wal_path).unwrap();
        wal.close().unwrap();

        assert_eq!(wal.state(), WalState::Closed);

        // Double close should be OK
        wal.close().unwrap();
    }

    #[test]
    fn test_sync_empty_wal() {
        let dir = tempdir().unwrap();
        let wal_path = dir.path().join("test.wal");

        let mut wal = Wal::create(&wal_path).unwrap();
        wal.sync().unwrap();

        assert!(!wal.sync_needed());
    }

    #[test]
    fn test_append_commit_record() {
        let dir = tempdir().unwrap();
        let wal_path = dir.path().join("test.wal");

        let mut wal = Wal::create(&wal_path).unwrap();

        let mutations = vec![
            super::super::record::Mutation::Put {
                key: vec![1, 2, 3],
                value: vec![4, 5, 6],
            },
        ];

        let record = CommitRecord::new(1, 0, mutations);
        let lsn = wal.append_commit_record(&record).unwrap();

        assert_eq!(lsn.as_u64(), 1);
        assert_eq!(wal.current_lsn(), 1);
        assert!(wal.sync_needed());
    }

    #[test]
    fn test_append_multiple_records() {
        let dir = tempdir().unwrap();
        let wal_path = dir.path().join("test.wal");

        let mut wal = Wal::create(&wal_path).unwrap();

        for i in 1..=10 {
            let mutations = vec![super::super::record::Mutation::Put {
                key: vec![i as u8],
                value: vec![i as u8],
            }];

            let record = CommitRecord::new(i, 0, mutations);
            let lsn = wal.append_commit_record(&record).unwrap();

            assert_eq!(lsn.as_u64(), i as u64);
        }

        assert_eq!(wal.current_lsn(), 10);
    }

    #[test]
    fn test_round_trip() {
        let dir = tempdir().unwrap();
        let wal_path = dir.path().join("test.wal");

        // Create WAL and append records
        {
            let mut wal = Wal::create(&wal_path).unwrap();

            for i in 1..=5 {
                let mutations = vec![super::super::record::Mutation::Put {
                    key: vec![i as u8],
                    value: vec![i as u8],
                }];

                let record = CommitRecord::new(i, 0, mutations);
                wal.append_commit_record(&record).unwrap();
            }

            wal.sync().unwrap();
        }

        // Reopen WAL
        let wal = Wal::open(&wal_path).unwrap();

        assert_eq!(wal.current_lsn(), 5);
    }

    #[test]
    fn test_buffer_flush() {
        let dir = tempdir().unwrap();
        let wal_path = dir.path().join("test.wal");

        let mut wal = Wal::create(&wal_path).unwrap();

        // Write enough data to flush buffer
        for i in 1..=1000 {
            let mutations = vec![super::super::record::Mutation::Put {
                key: vec![i as u8; 100],
                value: vec![i as u8; 100],
            }];

            let record = CommitRecord::new(i, 0, mutations);
            wal.append_commit_record(&record).unwrap();
        }

        assert_eq!(wal.current_lsn(), 1000);
        assert!(wal.sync_needed());
    }

    #[test]
    fn test_replay_empty_wal() {
        let dir = tempdir().unwrap();
        let wal_path = dir.path().join("test.wal");

        // Create empty WAL and sync
        {
            let mut wal = Wal::create(&wal_path).unwrap();
            wal.sync().unwrap();
        }

        // Reopen and replay
        let wal = Wal::open(&wal_path).unwrap();
        let mut iterator = wal.replay_ref().unwrap();

        // Should have no records
        assert_eq!(iterator.current_lsn(), 0);
        assert!(iterator.next().is_none());
    }

    #[test]
    fn test_replay_single_commit() {
        let dir = tempdir().unwrap();
        let wal_path = dir.path().join("test.wal");

        // Create WAL and append a record
        {
            let mut wal = Wal::create(&wal_path).unwrap();

            let mutations = vec![super::super::record::Mutation::Put {
                key: vec![1, 2, 3],
                value: vec![4, 5, 6],
            }];

            let record = CommitRecord::new(1, 0, mutations);
            wal.append_commit_record(&record).unwrap();
            wal.sync().unwrap();
        }

        // Reopen and replay
        let wal = Wal::open(&wal_path).unwrap();
        let mut iterator = wal.replay_ref().unwrap();

        // Should have one record
        let commit = iterator.next().unwrap().unwrap();
        assert_eq!(commit.txn_id(), 1);
        assert_eq!(commit.mutations().len(), 1);
        assert_eq!(iterator.current_lsn(), 1);

        // No more records
        assert!(iterator.next().is_none());
    }

    #[test]
    fn test_replay_multiple_commits() {
        let dir = tempdir().unwrap();
        let wal_path = dir.path().join("test.wal");

        // Create WAL and append multiple records
        {
            let mut wal = Wal::create(&wal_path).unwrap();

            for i in 1..=10 {
                let mutations = vec![super::super::record::Mutation::Put {
                    key: vec![i as u8],
                    value: vec![i as u8; 10],
                }];

                let record = CommitRecord::new(i, 0, mutations);
                wal.append_commit_record(&record).unwrap();
            }

            wal.sync().unwrap();
        }

        // Reopen and replay
        let wal = Wal::open(&wal_path).unwrap();
        let mut iterator = wal.replay_ref().unwrap();

        // Should have 10 records
        let mut count = 0;
        while let Some(result) = iterator.next() {
            let commit = result.unwrap();
            count += 1;
            assert_eq!(commit.txn_id(), count);
        }

        assert_eq!(count, 10);
        assert_eq!(iterator.current_lsn(), 10);
    }
}
