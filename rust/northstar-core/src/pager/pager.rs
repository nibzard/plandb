//! Main Pager API - page-based storage management.
//!
//! The Pager is the fundamental storage abstraction layer in NorthstarDB,
//! responsible for managing page-based I/O, page allocation, caching, and
//! file handle management.

use super::allocator::PageAllocator;
use super::cache::PageCache;
use super::meta::{choose_best_meta, MetaState};
use super::storage::Storage;
use crate::error::{Error, IoError, Result, ValidationError};
use crate::page::{Page, PageHeader, PageType, PAGE_MAGIC, PAGE_SIZE};
use crate::types::{Lsn, PageId, TransactionId};
use std::fs::File;
use std::path::Path;

/// Main Pager struct - manages page-based storage
pub struct Pager {
    /// Storage backend
    storage: Storage,
    /// Page size (fixed at database creation)
    page_size: u16,
    /// Current active meta state
    current_meta: MetaState,
    /// Page allocator
    allocator: PageAllocator,
    /// Page cache
    cache: PageCache,
}

impl Pager {
    /// Create a new in-memory database
    pub fn create_memory() -> Result<Self> {
        let storage = Storage::memory();
        let page_size = PAGE_SIZE as u16;

        // Create initial meta state
        let mut current_meta = MetaState::new(PageId::META_A);
        current_meta.update_committed_txn_id(TransactionId::INITIAL);

        // Initialize allocator
        let allocator = PageAllocator::new();

        // Initialize cache
        let cache = PageCache::new();

        let mut pager = Self {
            storage,
            page_size,
            current_meta,
            allocator,
            cache,
        };

        // Write initial meta pages
        pager.write_meta_pages()?;

        Ok(pager)
    }

    /// Create a new file-based database
    pub fn create_file(path: &Path) -> Result<Self> {
        // Create new file
        let file = File::create(path).map_err(|_e| Error::Io(IoError::FileNotFound {
            path: path.display().to_string(),
        }))?;

        let storage = Storage::file(file);
        let page_size = PAGE_SIZE as u16;

        // Create initial meta state
        let mut current_meta = MetaState::new(PageId::META_A);
        current_meta.update_committed_txn_id(TransactionId::INITIAL);

        // Initialize allocator
        let allocator = PageAllocator::new();

        // Initialize cache
        let cache = PageCache::new();

        let mut pager = Self {
            storage,
            page_size,
            current_meta,
            allocator,
            cache,
        };

        // Write initial meta pages
        pager.write_meta_pages()?;

        Ok(pager)
    }

    /// Open an existing database file
    pub fn open_file(path: &Path) -> Result<Self> {
        // Open file
        let file = File::open(path).map_err(|_e| Error::Io(IoError::FileNotFound {
            path: path.display().to_string(),
        }))?;

        let storage = Storage::file(file);

        // Read and validate meta pages
        let meta_a = Self::read_meta_page(&storage, PageId::META_A);
        let meta_b = Self::read_meta_page(&storage, PageId::META_B);

        // Choose best meta
        let best_meta = choose_best_meta(meta_a.as_ref(), meta_b.as_ref())
            .ok_or_else(|| {
                Error::Validation(ValidationError::CorruptedData)
            })?;

        // Validate page size
        let page_size = best_meta.page_size();
        if page_size as usize != PAGE_SIZE {
            return Err(Error::Validation(ValidationError::Generic(format!(
                "Unsupported page size: {} (expected {})",
                page_size, PAGE_SIZE
            ))));
        }

        // Initialize allocator
        let allocator = PageAllocator::new();

        // TODO: Rebuild free list (requires B+tree integration)
        // allocator.rebuild_freelist(&storage)?;

        // Initialize cache
        let cache = PageCache::new();

        Ok(Self {
            storage,
            page_size,
            current_meta: best_meta.clone(),
            allocator,
            cache,
        })
    }

    /// Close the pager and release resources
    pub fn close(&mut self) -> Result<()> {
        // Flush any pending writes
        self.storage.sync()?;

        // Clear cache
        self.cache.clear();

        Ok(())
    }

    /// Read a page from storage into buffer
    pub fn read_page(&mut self, page_id: PageId, buffer: &mut [u8]) -> Result<()> {
        // Validate buffer size
        if buffer.len() != PAGE_SIZE {
            return Err(Error::Validation(ValidationError::InvalidHeaderSize {
                expected: PAGE_SIZE,
                actual: buffer.len(),
            }));
        }

        // Read from storage
        self.storage.read_page(page_id.as_u64(), buffer)?;

        // Validate page
        Self::validate_page_buffer(page_id, buffer)?;

        Ok(())
    }

    /// Write a page from buffer to storage
    pub fn write_page(&mut self, page_id: PageId, buffer: &[u8]) -> Result<()> {
        // Validate buffer size
        if buffer.len() != PAGE_SIZE {
            return Err(Error::Validation(ValidationError::InvalidHeaderSize {
                expected: PAGE_SIZE,
                actual: buffer.len(),
            }));
        }

        // Validate page structure
        Self::validate_page_buffer(page_id, buffer)?;

        // Write to storage
        self.storage.write_page(page_id.as_u64(), buffer)?;

        // Invalidate cache entry
        self.cache.remove(page_id);

        Ok(())
    }

    /// Read a page with caching
    ///
    /// Returns owned Vec<u8> with page data. For zero-copy access,
    /// use the cache API directly.
    pub fn read_page_cached(&mut self, page_id: PageId) -> Result<Vec<u8>> {
        // Check cache first
        if self.cache.contains(page_id) {
            // Get the data and immediately copy it to avoid borrow issues
            let data = {
                let cached_data = self.cache.get(page_id).unwrap();
                cached_data.to_vec()
            };
            self.cache.unpin(page_id);
            return Ok(data);
        }

        // Cache miss - read from storage
        let mut buffer = vec![0u8; PAGE_SIZE];
        self.read_page(page_id, &mut buffer)?;

        // Insert into cache
        self.cache.put(page_id, &buffer)?;

        // Unpin and return copy
        self.cache.unpin(page_id);
        Ok(buffer)
    }

    /// Unpin a cached page
    pub fn unpin_page(&mut self, page_id: PageId) {
        self.cache.unpin(page_id);
    }

    /// Allocate a new page
    pub fn allocate_page(&mut self) -> Result<PageId> {
        let page_id = self.allocator.allocate_page()?;

        // Initialize page with zeros and valid header
        let mut page = Page::new(page_id, PageType::Freelist);
        page.recalculate_checksums();

        // Write to storage
        let page_bytes = page.to_bytes();
        self.storage.write_page(page_id.as_u64(), &page_bytes)?;

        Ok(page_id)
    }

    /// Free a page
    pub fn free_page(&mut self, page_id: PageId) -> Result<()> {
        self.allocator.free_page(page_id)?;

        // Invalidate cache entry
        self.cache.remove(page_id);

        Ok(())
    }

    /// Read a B+Tree node from storage
    pub fn read_btree_node(&mut self, page_id: PageId) -> Result<crate::btree::node::Node> {
        use crate::btree::node::Node;

        let bytes = self.read_page_cached(page_id)?;
        Node::from_bytes(&bytes)
    }

    /// Write a B+Tree node to storage
    pub fn write_btree_node(&mut self, page_id: PageId, node: &crate::btree::node::Node) -> Result<()> {
        let bytes = node.to_bytes();
        self.write_page(page_id, &bytes)
    }

    /// Get the root page ID
    pub fn root_page_id(&self) -> PageId {
        self.current_meta.root_page_id()
    }

    /// Get the committed transaction ID
    pub fn committed_txn_id(&self) -> TransactionId {
        self.current_meta.committed_txn_id()
    }

    /// Get the free list head page ID
    pub fn freelist_head_page_id(&self) -> PageId {
        self.current_meta.freelist_head_page_id()
    }

    /// Get the log tail LSN
    pub fn log_tail_lsn(&self) -> Lsn {
        self.current_meta.log_tail_lsn()
    }

    /// Get the page size
    pub fn page_size(&self) -> u16 {
        self.page_size
    }

    /// Get cache statistics
    pub fn cache_stats(&self) -> super::cache::CacheStats {
        self.cache.stats()
    }

    /// Sync data to stable storage
    pub fn sync(&self) -> Result<()> {
        self.storage.sync()
    }

    /// Read a meta page from storage
    fn read_meta_page(storage: &Storage, page_id: PageId) -> Option<MetaState> {
        let mut buffer = vec![0u8; PAGE_SIZE];

        // Try to read the page
        if storage.read_page(page_id.as_u64(), &mut buffer).is_err() {
            return None;
        }

        // Try to parse as page
        let page = Page::from_bytes(&buffer).ok()?;

        // Try to parse as meta state
        MetaState::from_page(&page).ok()
    }

    /// Write both meta pages
    fn write_meta_pages(&mut self) -> Result<()> {
        // Write meta A
        let page_a = self.current_meta.to_page();
        let bytes_a = page_a.to_bytes();
        self.storage.write_page(PageId::META_A.as_u64(), &bytes_a)?;

        // Write meta B (with same content for now)
        let page_b = self.current_meta.to_page();
        let bytes_b = page_b.to_bytes();
        self.storage.write_page(PageId::META_B.as_u64(), &bytes_b)?;

        Ok(())
    }

    /// Validate a page buffer
    fn validate_page_buffer(page_id: PageId, buffer: &[u8]) -> Result<()> {
        // Parse page header
        let header = unsafe {
            let ptr = buffer.as_ptr() as *const PageHeader;
            ptr.read_unaligned()
        };

        // Check magic number
        if header.magic != PAGE_MAGIC {
            return Err(Error::Validation(ValidationError::InvalidMagic {
                expected: PAGE_MAGIC,
                actual: header.magic,
            }));
        }

        // Check page ID matches
        if header.page_id != page_id.as_u64() {
            return Err(Error::Validation(ValidationError::Generic(format!(
                "Page ID mismatch: expected {}, got {}",
                page_id.as_u64(),
                header.page_id
            ))));
        }

        // Validate header
        header.validate()?;

        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_create_memory() {
        let pager = Pager::create_memory().unwrap();

        assert_eq!(pager.page_size(), PAGE_SIZE as u16);
        assert_eq!(pager.committed_txn_id(), TransactionId::INITIAL);
        assert_eq!(pager.root_page_id(), crate::PageId::FIRST_DATA);
    }

    #[test]
    fn test_allocate_page() {
        let mut pager = Pager::create_memory().unwrap();

        let _page1 = pager.allocate_page().unwrap();
        assert_eq!(_page1.as_u64(), 2); // First data page after meta pages

        let _page2 = pager.allocate_page().unwrap();
        assert_eq!(_page2.as_u64(), 3);
    }

    #[test]
    fn test_free_and_reuse_page() {
        let mut pager = Pager::create_memory().unwrap();

        let _page1 = pager.allocate_page().unwrap(); // ID 2
        let page2 = pager.allocate_page().unwrap(); // ID 3
        let _page3 = pager.allocate_page().unwrap(); // ID 4

        // Free page2 (ID 3)
        pager.free_page(page2).unwrap();

        // Next allocation should reuse page 3 (which was freed)
        let reused = pager.allocate_page().unwrap();
        assert_eq!(reused.as_u64(), 3);
    }

    #[test]
    fn test_free_meta_page_rejected() {
        let mut pager = Pager::create_memory().unwrap();

        let result = pager.free_page(PageId::META_A);
        assert!(result.is_err());

        let result = pager.free_page(PageId::META_B);
        assert!(result.is_err());
    }

    #[test]
    fn test_read_page_cached() {
        let mut pager = Pager::create_memory().unwrap();

        let page_id = pager.allocate_page().unwrap();

        // First read should be cache miss
        let data1 = pager.read_page_cached(page_id).unwrap();

        // Second read should be cache hit
        let data2 = pager.read_page_cached(page_id).unwrap();

        // Both should return the same data
        assert_eq!(data1, data2);
    }

    #[test]
    fn test_write_and_read_page() {
        let mut pager = Pager::create_memory().unwrap();

        let page_id = pager.allocate_page().unwrap();

        // Create test page data
        let mut page = Page::new(page_id, PageType::BtreeLeaf);
        let payload = b"test data for page".to_vec();
        page.update_payload(payload).unwrap();

        let page_bytes = page.to_bytes();

        // Write page
        pager.write_page(page_id, &page_bytes).unwrap();

        // Read page back
        let mut read_buffer = vec![0u8; PAGE_SIZE];
        pager.read_page(page_id, &mut read_buffer).unwrap();

        // Verify data
        assert_eq!(&read_buffer[..PAGE_SIZE], &page_bytes[..PAGE_SIZE]);
    }

    #[test]
    fn test_cache_stats() {
        let mut pager = Pager::create_memory().unwrap();

        let stats = pager.cache_stats();
        assert_eq!(stats.total_pages, 0);

        // Allocate and cache a page
        let page_id = pager.allocate_page().unwrap();
        let _data = pager.read_page_cached(page_id).unwrap();

        let stats = pager.cache_stats();
        assert_eq!(stats.total_pages, 1);
    }
}
