//! Storage abstraction for page-based I/O.
//!
//! Provides unified interface for file-based and memory-based storage backends.

use crate::error::{Error, IoError, Result};
use crate::page::PAGE_SIZE;
use std::fs::File;
use std::io::{Read, Seek, SeekFrom, Write};
use std::sync::{Arc, Mutex};

/// Storage backend abstraction
pub enum Storage {
    /// File-based persistent storage
    File(FileStorage),
    /// In-memory transient storage
    Memory(MemoryStorage),
}

impl Storage {
    /// Create file-based storage
    pub fn file(file: File) -> Self {
        Self::File(FileStorage::new(file))
    }

    /// Create memory-based storage
    pub fn memory() -> Self {
        Self::Memory(MemoryStorage::new())
    }

    /// Read a page from storage into buffer
    pub fn read_page(&self, page_id: u64, buffer: &mut [u8]) -> Result<()> {
        match self {
            Self::File(fs) => fs.read_page(page_id, buffer),
            Self::Memory(ms) => ms.read_page(page_id, buffer),
        }
    }

    /// Write a page from buffer to storage
    pub fn write_page(&self, page_id: u64, buffer: &[u8]) -> Result<()> {
        match self {
            Self::File(fs) => fs.write_page(page_id, buffer),
            Self::Memory(ms) => ms.write_page(page_id, buffer),
        }
    }

    /// Sync data to stable storage (no-op for memory)
    pub fn sync(&self) -> Result<()> {
        match self {
            Self::File(fs) => fs.sync(),
            Self::Memory(_) => Ok(()), // No-op for memory storage
        }
    }

    /// Get current file/storage size in bytes
    pub fn size(&self) -> Result<u64> {
        match self {
            Self::File(fs) => fs.size(),
            Self::Memory(ms) => ms.size(),
        }
    }

    /// Check if this is file-based storage
    pub fn is_file(&self) -> bool {
        matches!(self, Self::File(_))
    }

    /// Check if this is memory-based storage
    pub fn is_memory(&self) -> bool {
        matches!(self, Self::Memory(_))
    }
}

/// File-based storage using std::fs::File
pub struct FileStorage {
    file: Mutex<File>,
}

impl FileStorage {
    /// Create new file storage from File handle
    pub fn new(file: File) -> Self {
        Self {
            file: Mutex::new(file),
        }
    }

    /// Read a page at the given offset
    fn read_page(&self, page_id: u64, buffer: &mut [u8]) -> Result<()> {
        // Validate buffer size
        if buffer.len() != PAGE_SIZE {
            return Err(Error::Io(IoError::InternalError(format!(
                "Buffer size mismatch: expected {}, got {}",
                PAGE_SIZE,
                buffer.len()
            ))));
        }

        let mut file = self.file.lock().map_err(|e| {
            Error::Io(IoError::InternalError(format!(
                "Failed to acquire file lock: {}",
                e
            )))
        })?;

        // Calculate offset
        let offset = page_id.checked_mul(PAGE_SIZE as u64).ok_or_else(|| {
            Error::Io(IoError::InternalError(format!(
                "Page ID overflow: {} * {}",
                page_id, PAGE_SIZE
            )))
        })?;

        // Seek to offset
        file.seek(SeekFrom::Start(offset))
            .map_err(|e| Error::Io(IoError::Generic(e)))?;

        // Read exactly PAGE_SIZE bytes
        file.read_exact(buffer).map_err(|e| {
            if e.kind() == std::io::ErrorKind::UnexpectedEof {
                Error::Io(IoError::FileTooSmall {
                    path: "unknown".to_string(),
                    size: offset as u64,
                    expected: (offset + PAGE_SIZE as u64),
                })
            } else {
                Error::Io(IoError::Generic(e))
            }
        })?;

        Ok(())
    }

    /// Write a page at the given offset
    fn write_page(&self, page_id: u64, buffer: &[u8]) -> Result<()> {
        // Validate buffer size
        if buffer.len() != PAGE_SIZE {
            return Err(Error::Io(IoError::InternalError(format!(
                "Buffer size mismatch: expected {}, got {}",
                PAGE_SIZE,
                buffer.len()
            ))));
        }

        let mut file = self.file.lock().map_err(|e| {
            Error::Io(IoError::InternalError(format!(
                "Failed to acquire file lock: {}",
                e
            )))
        })?;

        // Calculate offset
        let offset = page_id.checked_mul(PAGE_SIZE as u64).ok_or_else(|| {
            Error::Io(IoError::InternalError(format!(
                "Page ID overflow: {} * {}",
                page_id, PAGE_SIZE
            )))
        })?;

        // Seek to offset
        file.seek(SeekFrom::Start(offset))
            .map_err(|e| Error::Io(IoError::Generic(e)))?;

        // Write exactly PAGE_SIZE bytes
        file.write_all(buffer).map_err(|e| Error::Io(IoError::Generic(e)))?;

        Ok(())
    }

    /// Sync data to disk
    fn sync(&self) -> Result<()> {
        let file = self.file.lock().map_err(|e| {
            Error::Io(IoError::InternalError(format!(
                "Failed to acquire file lock: {}",
                e
            )))
        })?;

        file.sync_all().map_err(|e| Error::Io(IoError::Generic(e)))?;
        Ok(())
    }

    /// Get file size
    fn size(&self) -> Result<u64> {
        let mut file = self.file.lock().map_err(|e| {
            Error::Io(IoError::InternalError(format!(
                "Failed to acquire file lock: {}",
                e
            )))
        })?;

        let pos = file
            .seek(SeekFrom::End(0))
            .map_err(|e| Error::Io(IoError::Generic(e)))?;

        // Seek back to start
        file.seek(SeekFrom::Start(0))
            .map_err(|e| Error::Io(IoError::Generic(e)))?;

        Ok(pos)
    }
}

/// In-memory storage for testing and temporary databases
pub struct MemoryStorage {
    data: Arc<Mutex<Vec<u8>>>,
}

impl MemoryStorage {
    /// Create new in-memory storage
    pub fn new() -> Self {
        Self {
            data: Arc::new(Mutex::new(Vec::new())),
        }
    }

    /// Read a page from memory
    fn read_page(&self, page_id: u64, buffer: &mut [u8]) -> Result<()> {
        // Validate buffer size
        if buffer.len() != PAGE_SIZE {
            return Err(Error::Io(IoError::InternalError(format!(
                "Buffer size mismatch: expected {}, got {}",
                PAGE_SIZE,
                buffer.len()
            ))));
        }

        let data = self.data.lock().map_err(|e| {
            Error::Io(IoError::InternalError(format!(
                "Failed to acquire data lock: {}",
                e
            )))
        })?;

        // Calculate offset
        let offset = page_id.checked_mul(PAGE_SIZE as u64).ok_or_else(|| {
            Error::Io(IoError::InternalError(format!(
                "Page ID overflow: {} * {}",
                page_id, PAGE_SIZE
            )))
        })? as usize;

        let end_offset = offset + PAGE_SIZE;

        // Check bounds
        if end_offset > data.len() {
            return Err(Error::Io(IoError::FileTooSmall {
                path: ":memory:".to_string(),
                size: data.len() as u64,
                expected: end_offset as u64,
            }));
        }

        // Copy data to buffer
        buffer.copy_from_slice(&data[offset..end_offset]);

        Ok(())
    }

    /// Write a page to memory
    fn write_page(&self, page_id: u64, buffer: &[u8]) -> Result<()> {
        // Validate buffer size
        if buffer.len() != PAGE_SIZE {
            return Err(Error::Io(IoError::InternalError(format!(
                "Buffer size mismatch: expected {}, got {}",
                PAGE_SIZE,
                buffer.len()
            ))));
        }

        let mut data = self.data.lock().map_err(|e| {
            Error::Io(IoError::InternalError(format!(
                "Failed to acquire data lock: {}",
                e
            )))
        })?;

        // Calculate offset
        let offset = page_id.checked_mul(PAGE_SIZE as u64).ok_or_else(|| {
            Error::Io(IoError::InternalError(format!(
                "Page ID overflow: {} * {}",
                page_id, PAGE_SIZE
            )))
        })? as usize;

        let end_offset = offset + PAGE_SIZE;

        // Extend vector if necessary
        if end_offset > data.len() {
            data.resize(end_offset, 0);
        }

        // Copy buffer to data
        data[offset..end_offset].copy_from_slice(buffer);

        Ok(())
    }

    /// Get current size
    fn size(&self) -> Result<u64> {
        let data = self.data.lock().map_err(|e| {
            Error::Io(IoError::InternalError(format!(
                "Failed to acquire data lock: {}",
                e
            )))
        })?;

        Ok(data.len() as u64)
    }
}

impl Default for MemoryStorage {
    fn default() -> Self {
        Self::new()
    }
}

impl Clone for MemoryStorage {
    fn clone(&self) -> Self {
        Self {
            data: Arc::clone(&self.data),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_memory_storage_read_write() {
        let storage = MemoryStorage::new();

        // Write page 0
        let page_data = vec![0xABu8; PAGE_SIZE];
        storage.write_page(0, &page_data).unwrap();

        // Read page 0
        let mut read_buffer = vec![0u8; PAGE_SIZE];
        storage.read_page(0, &mut read_buffer).unwrap();

        assert_eq!(read_buffer, page_data);
    }

    #[test]
    fn test_memory_storage_size() {
        let storage = MemoryStorage::new();
        assert_eq!(storage.size().unwrap(), 0);

        // Write page 0
        let page_data = vec![0xABu8; PAGE_SIZE];
        storage.write_page(0, &page_data).unwrap();

        assert_eq!(storage.size().unwrap(), PAGE_SIZE as u64);

        // Write page 1
        storage.write_page(1, &page_data).unwrap();

        assert_eq!(storage.size().unwrap(), (PAGE_SIZE * 2) as u64);
    }

    #[test]
    fn test_memory_storage_read_out_of_bounds() {
        let storage = MemoryStorage::new();

        let mut read_buffer = vec![0u8; PAGE_SIZE];
        let result = storage.read_page(0, &mut read_buffer);

        assert!(matches!(
            result,
            Err(Error::Io(IoError::FileTooSmall { .. }))
        ));
    }

    #[test]
    fn test_memory_storage_wrong_buffer_size() {
        let storage = MemoryStorage::new();

        let wrong_buffer = vec![0u8; PAGE_SIZE / 2];
        let result = storage.write_page(0, &wrong_buffer);

        assert!(result.is_err());
    }

    #[test]
    fn test_storage_is_file() {
        // For this test, we'll just test memory storage
        // File storage testing requires actual file I/O which is tested elsewhere
        let storage = Storage::Memory(MemoryStorage::new());
        assert!(storage.is_memory());
        assert!(!storage.is_file());
    }

    #[test]
    fn test_storage_is_memory() {
        let storage = Storage::Memory(MemoryStorage::new());
        assert!(storage.is_memory());
        assert!(!storage.is_file());
    }

    #[test]
    fn test_storage_memory_noop_sync() {
        let storage = Storage::Memory(MemoryStorage::new());
        assert!(storage.sync().is_ok());
    }

    #[test]
    fn test_memory_storage_clone() {
        let storage1 = MemoryStorage::new();

        let page_data = vec![0xABu8; PAGE_SIZE];
        storage1.write_page(0, &page_data).unwrap();

        let storage2 = storage1.clone();

        let mut read_buffer = vec![0u8; PAGE_SIZE];
        storage2.read_page(0, &mut read_buffer).unwrap();

        assert_eq!(read_buffer, page_data);
    }

    #[test]
    fn test_memory_storage_multiple_pages() {
        let storage = MemoryStorage::new();

        // Write multiple pages with different data
        for i in 0..5 {
            let page_data = vec![i as u8; PAGE_SIZE];
            storage.write_page(i, &page_data).unwrap();
        }

        // Read and verify each page
        for i in 0..5 {
            let mut read_buffer = vec![0u8; PAGE_SIZE];
            storage.read_page(i, &mut read_buffer).unwrap();

            let expected = vec![i as u8; PAGE_SIZE];
            assert_eq!(read_buffer, expected);
        }
    }
}
