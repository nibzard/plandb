//! Main Pager API - page-based storage management.
//!
//! The Pager is the fundamental storage abstraction layer in NorthstarDB,
//! responsible for managing page-based I/O, page allocation, caching, and
//! file handle management.

use super::allocator::PageAllocator;
use super::meta::{choose_best_meta, MetaState};
use super::storage::Storage;
use crate::cache::{PageCache, PrefetchPriority, PrefetchQueue};
use crate::btree::overflow::{OverflowPage, OVERFLOW_DATA_SIZE, OVERFLOW_MAGIC};
use crate::error::{Error, IoError, Result, ValidationError};
use crate::page::{Page, PageHeader, PageType, PAGE_MAGIC, PAGE_SIZE};
use crate::types::{Lsn, PageId, TransactionId};
use std::fs::File;
use std::path::Path;
use std::fs::OpenOptions;
use std::sync::Arc;

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
    /// Prefetch queue for async page loading
    prefetch_queue: Arc<PrefetchQueue>,
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

        // Initialize prefetch queue
        let prefetch_queue = Arc::new(PrefetchQueue::new());

        let mut pager = Self {
            storage,
            page_size,
            current_meta,
            allocator,
            cache,
            prefetch_queue,
        };

        // Write initial meta pages
        pager.write_meta_pages()?;

        Ok(pager)
    }

    /// Create a new file-based database
    pub fn create_file(path: &Path) -> Result<Self> {
        // Create new file in read-write mode
        // File::create() opens in write-only mode, which fails on read
        let file = OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(false)
            .open(path)
            .map_err(|_e| Error::Io(IoError::FileNotFound {
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

        // Initialize prefetch queue
        let prefetch_queue = Arc::new(PrefetchQueue::new());

        let mut pager = Self {
            storage,
            page_size,
            current_meta,
            allocator,
            cache,
            prefetch_queue,
        };

        // Write initial meta pages
        pager.write_meta_pages()?;

        // Initialize empty B+Tree root page (page 2 = FIRST_DATA)
        // This is needed because BTree::new() expects to read the root page
        let root_page_id = PageId::FIRST_DATA;
        let root_node = crate::btree::node::Node::Leaf(crate::btree::node::LeafNode::new(root_page_id.as_u64()));
        pager.write_btree_node(root_page_id, &root_node)?;

        // Sync to ensure everything is persisted
        pager.storage.sync()?;

        Ok(pager)
    }

    /// Open an existing database file
    pub fn open_file(path: &Path) -> Result<Self> {
        // Open file in read-write mode
        let file = OpenOptions::new()
            .read(true)
            .write(true)
            .open(path)
            .map_err(|_e| Error::Io(IoError::FileNotFound {
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

        // Initialize prefetch queue
        let prefetch_queue = Arc::new(PrefetchQueue::new());

        Ok(Self {
            storage,
            page_size,
            current_meta: best_meta.clone(),
            allocator,
            cache,
            prefetch_queue,
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

    /// Read a page without validation (for B+Tree nodes which use NODE_MAGIC)
    fn read_page_raw(&mut self, page_id: PageId, buffer: &mut [u8]) -> Result<()> {
        // Validate buffer size
        if buffer.len() != PAGE_SIZE {
            return Err(Error::Validation(ValidationError::InvalidHeaderSize {
                expected: PAGE_SIZE,
                actual: buffer.len(),
            }));
        }

        // Read from storage without validation
        self.storage.read_page(page_id.as_u64(), buffer)?;

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

        // Update cache with new data instead of removing
        // This ensures cache always has the latest data from storage
        let _ = self.cache.put(page_id, buffer);

        Ok(())
    }

    /// Write a page without validation (for B+Tree nodes which use NODE_MAGIC)
    fn write_page_raw(&mut self, page_id: PageId, buffer: &[u8]) -> Result<()> {
        // Validate buffer size
        if buffer.len() != PAGE_SIZE {
            return Err(Error::Validation(ValidationError::InvalidHeaderSize {
                expected: PAGE_SIZE,
                actual: buffer.len(),
            }));
        }

        // Write to storage without validation
        self.storage.write_page(page_id.as_u64(), buffer)?;

        // Invalidate any stale cache entry first
        // Then add fresh data to cache
        self.cache.remove(page_id);
        self.cache.put(page_id, buffer)?;

        Ok(())
    }

    /// Read a page with caching
    ///
    /// Returns owned Vec<u8> with page data. For zero-copy access,
    /// use the cache API directly.
    pub fn read_page_cached(&mut self, page_id: PageId) -> Result<Vec<u8>> {
        // Check cache first
        if self.cache.contains(page_id) {
            // Get the data - cache.get() handles pin/unpin internally
            let cached_data = self.cache.get(page_id).unwrap();
            return Ok(cached_data);
        }

        // Cache miss - read from storage
        let mut buffer = vec![0u8; PAGE_SIZE];
        self.read_page(page_id, &mut buffer)?;

        // Insert into cache (starts pinned, need to unpin)
        self.cache.put(page_id, &buffer)?;
        self.cache.unpin(page_id);
        Ok(buffer)
    }

    /// Read a page without validation (for B+Tree nodes which use NODE_MAGIC)
    fn read_page_cached_raw(&mut self, page_id: PageId) -> Result<Vec<u8>> {
        // Check cache first
        if self.cache.contains(page_id) {
            // Get the data - cache.get() handles pin/unpin internally
            let cached_data = self.cache.get(page_id).unwrap();
            return Ok(cached_data);
        }

        // Cache miss - read from storage without validation
        let mut buffer = vec![0u8; PAGE_SIZE];
        self.read_page_raw(page_id, &mut buffer)?;

        // Insert into cache (starts pinned, need to unpin)
        self.cache.put(page_id, &buffer)?;
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

        // Initialize page with valid header
        let mut page = Page::new(page_id, PageType::Freelist);
        page.recalculate_checksums();

        // Write to storage
        let page_bytes = page.to_bytes();
        self.storage.write_page(page_id.as_u64(), &page_bytes)?;

        // NOTE: Don't update cache here - the caller will write the actual content
        // (e.g., B+Tree node with NODE_MAGIC) which will update the cache.
        // If we update cache here with PAGE_MAGIC, it will overwrite the correct data
        // that the caller writes.

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

        // Use raw read to skip PAGE_MAGIC validation (B+Tree nodes use NODE_MAGIC)
        let bytes = self.read_page_cached_raw(page_id)?;
        Node::from_bytes(&bytes)
    }

    /// Write a B+Tree node to storage
    pub fn write_btree_node(&mut self, page_id: PageId, node: &crate::btree::node::Node) -> Result<()> {
        let bytes = node.to_bytes();
        // Use raw write to skip PAGE_MAGIC validation (B+Tree nodes use NODE_MAGIC)
        self.write_page_raw(page_id, &bytes)
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
    pub fn cache_stats(&self) -> crate::cache::types::CacheSnapshot {
        self.cache.stats()
    }

    /// Sync data to stable storage
    pub fn sync(&self) -> Result<()> {
        self.storage.sync()
    }

    // ========== Prefetch API ==========

    /// Prefetch a single page with given priority
    ///
    /// Adds the page to the prefetch queue for async loading.
    /// Returns true if the request was queued, false if queue is full.
    pub fn prefetch_hint(&self, page_id: PageId, priority: PrefetchPriority) -> bool {
        use crate::cache::PrefetchRequest;
        let request = PrefetchRequest::new(page_id, priority);
        self.prefetch_queue.enqueue(request)
    }

    /// Prefetch multiple pages with given priority
    ///
    /// Adds all pages to the prefetch queue.
    /// Returns the number of pages successfully queued.
    pub fn prefetch_hint_batch(&self, page_ids: Vec<PageId>, priority: PrefetchPriority) -> usize {
        use crate::cache::PrefetchRequest;
        let mut enqueued = 0;
        for page_id in page_ids {
            let request = PrefetchRequest::new(page_id, priority);
            if self.prefetch_queue.enqueue(request) {
                enqueued += 1;
            }
        }
        enqueued
    }

    /// Get the prefetch queue for direct access
    pub fn prefetch_queue(&self) -> &Arc<PrefetchQueue> {
        &self.prefetch_queue
    }

    // ========== Overflow Page Management ==========

    /// Allocate a new overflow page
    pub fn allocate_overflow_page(&mut self) -> Result<PageId> {
        let page_id = self.allocate_page()?;

        // Initialize overflow page with valid structure
        let overflow_page = OverflowPage::new();
        self.write_overflow_page(page_id, &overflow_page)?;

        Ok(page_id)
    }

    /// Read an overflow page from storage
    pub fn read_overflow_page(&mut self, page_id: PageId) -> Result<OverflowPage> {
        // Read the full page from storage
        let page_bytes = self.read_page_cached(page_id)?;

        // Parse as Page to validate structure
        let page = Page::from_bytes(&page_bytes)?;

        // Verify it's an overflow page type
        if page.page_type() != Some(PageType::Overflow) {
            return Err(Error::Validation(ValidationError::Generic(format!(
                "Expected overflow page, got {:?}", page.page_type()
            ))));
        }

        // Parse the payload as OverflowPage
        let overflow_page = OverflowPage::from_bytes(&page.payload)?;

        Ok(overflow_page)
    }

    /// Write an overflow page to storage
    pub fn write_overflow_page(&mut self, page_id: PageId, overflow_page: &OverflowPage) -> Result<()> {
        // Validate overflow page
        overflow_page.validate()?;

        // Create page with overflow type
        let mut page = Page::new(page_id, PageType::Overflow);

        // Serialize overflow page as payload
        let payload = overflow_page.to_bytes();
        page.update_payload(payload)?;

        // Write page
        let page_bytes = page.to_bytes();
        self.write_page(page_id, &page_bytes)
    }

    /// Allocate a chain of overflow pages for a large value
    ///
    /// Returns the first page ID of the chain
    pub fn allocate_overflow_chain(&mut self, value: &[u8]) -> Result<PageId> {
        if value.is_empty() {
            return Err(Error::Validation(ValidationError::Generic(
                "Cannot allocate overflow chain for empty value".to_string()
            )));
        }

        let num_pages = OverflowPage::pages_needed(value.len());
        let mut first_page_id = None;
        let mut prev_page_id = None;

        for i in 0..num_pages {
            let page_id = self.allocate_overflow_page()?;

            let start = i * OVERFLOW_DATA_SIZE;
            let end = std::cmp::min(start + OVERFLOW_DATA_SIZE, value.len());
            let chunk = value[start..end].to_vec();

            let overflow_page = OverflowPage::with_data(chunk, 0);
            self.write_overflow_page(page_id, &overflow_page)?;

            // Link pages
            if let Some(prev_id) = prev_page_id {
                let mut prev_page = self.read_overflow_page(prev_id)?;
                prev_page.set_next_page(page_id);
                self.write_overflow_page(prev_id, &prev_page)?;
            } else {
                first_page_id = Some(page_id);
            }

            prev_page_id = Some(page_id);
        }

        first_page_id.ok_or_else(|| {
            Error::Validation(ValidationError::Generic(
                "Failed to allocate any overflow pages".to_string()
            ))
        })
    }

    /// Read a complete value from an overflow page chain
    pub fn read_overflow_chain(&mut self, first_page_id: PageId) -> Result<Vec<u8>> {
        let mut buffer = Vec::new();
        let mut current_page_id = first_page_id;
        let mut visited = std::collections::HashSet::new();

        loop {
            // Check for circular references
            if !visited.insert(current_page_id) {
                return Err(Error::Validation(ValidationError::Generic(
                    format!("Circular reference detected in overflow chain at page {}", current_page_id.as_u64())
                )));
            }

            // Limit chain length to prevent infinite loops
            if visited.len() > 2000 {
                return Err(Error::Validation(ValidationError::Generic(
                    "Overflow chain too long (max 2000 pages)".to_string()
                )));
            }

            let overflow_page = self.read_overflow_page(current_page_id)?;

            // Append data chunk
            buffer.extend_from_slice(&overflow_page.data);

            // Check if last page
            if overflow_page.is_last() {
                break;
            }

            current_page_id = overflow_page.get_next_page();
        }

        Ok(buffer)
    }

    /// Free an overflow page chain
    ///
    /// NOTE: This should be called after all snapshots that might reference
    /// the chain have been released (MVCC safety)
    pub fn free_overflow_chain(&mut self, first_page_id: PageId) -> Result<()> {
        let mut current_page_id = first_page_id;
        let mut visited = std::collections::HashSet::new();

        loop {
            // Check for circular references
            if !visited.insert(current_page_id) {
                return Err(Error::Validation(ValidationError::Generic(
                    format!("Circular reference detected in overflow chain at page {}", current_page_id.as_u64())
                )));
            }

            // Limit chain length
            if visited.len() > 2000 {
                return Err(Error::Validation(ValidationError::Generic(
                    "Overflow chain too long (max 2000 pages)".to_string()
                )));
            }

            let overflow_page = self.read_overflow_page(current_page_id)?;
            let next_page_id = overflow_page.get_next_page();

            self.free_page(current_page_id)?;

            if next_page_id.as_u64() == 0 {
                break;
            }

            current_page_id = next_page_id;
        }

        Ok(())
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

    /// Update and persist meta pages with new transaction state.
    ///
    /// This should be called after transaction commit to update the
    /// committed transaction ID and root page ID in the meta pages.
    ///
    /// # Arguments
    ///
    /// * `txn_id` - New committed transaction ID
    /// * `root_page_id` - New root page ID
    pub fn commit_transaction(&mut self, txn_id: TransactionId, root_page_id: PageId) -> Result<()> {
        // Update current meta state
        self.current_meta.update_committed_txn_id(txn_id);
        self.current_meta.update_root_page_id(root_page_id);

        // Write both meta pages
        self.write_meta_pages()?;

        // Sync to ensure meta pages are persisted
        self.storage.sync()?;

        Ok(())
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
        assert_eq!(_page1.as_u64(), 3); // First data page after meta pages and B+Tree root

        let _page2 = pager.allocate_page().unwrap();
        assert_eq!(_page2.as_u64(), 4);
    }

    #[test]
    fn test_free_and_reuse_page() {
        let mut pager = Pager::create_memory().unwrap();

        let _page1 = pager.allocate_page().unwrap(); // ID 3
        let page2 = pager.allocate_page().unwrap(); // ID 4
        let _page3 = pager.allocate_page().unwrap(); // ID 5

        // Free page2 (ID 4)
        pager.free_page(page2).unwrap();

        // Next allocation should reuse page 4 (which was freed)
        let reused = pager.allocate_page().unwrap();
        assert_eq!(reused.as_u64(), 4);
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
        assert_eq!(stats.current_entries, 0);

        // Allocate and cache a page
        let page_id = pager.allocate_page().unwrap();
        let _data = pager.read_page_cached(page_id).unwrap();

        let stats = pager.cache_stats();
        assert_eq!(stats.current_entries, 1);
    }

    #[test]
    fn test_allocate_overflow_page() {
        let mut pager = Pager::create_memory().unwrap();

        let page_id = pager.allocate_overflow_page().unwrap();

        // Read back and verify
        let overflow_page = pager.read_overflow_page(page_id).unwrap();
        assert_eq!(overflow_page.magic, OVERFLOW_MAGIC);
        assert_eq!(overflow_page.next_page, 0);
        assert_eq!(overflow_page.data.len(), 0);
    }

    #[test]
    fn test_write_and_read_overflow_page() {
        let mut pager = Pager::create_memory().unwrap();

        let page_id = pager.allocate_overflow_page().unwrap();

        // Write data
        let data = vec![1u8, 2, 3, 4, 5];
        let mut overflow_page = OverflowPage::with_data(data.clone(), 42);
        pager.write_overflow_page(page_id, &overflow_page).unwrap();

        // Read back
        let read_page = pager.read_overflow_page(page_id).unwrap();
        assert_eq!(read_page.data, data);
        assert_eq!(read_page.next_page, 42);
    }

    #[test]
    fn test_allocate_overflow_chain_single_page() {
        let mut pager = Pager::create_memory().unwrap();

        let value = vec![1u8, 2, 3, 4, 5];
        let first_page_id = pager.allocate_overflow_chain(&value).unwrap();

        // Read back
        let read_value = pager.read_overflow_chain(first_page_id).unwrap();
        assert_eq!(read_value, value);
    }

    #[test]
    fn test_allocate_overflow_chain_multiple_pages() {
        let mut pager = Pager::create_memory().unwrap();

        // Create value larger than OVERFLOW_DATA_SIZE
        let value = vec![42u8; OVERFLOW_DATA_SIZE + 100];
        let first_page_id = pager.allocate_overflow_chain(&value).unwrap();

        // Read back
        let read_value = pager.read_overflow_chain(first_page_id).unwrap();
        assert_eq!(read_value.len(), value.len());
        assert_eq!(read_value, value);
    }

    #[test]
    fn test_free_overflow_chain() {
        let mut pager = Pager::create_memory().unwrap();

        let value = vec![1u8, 2, 3, 4, 5];
        let first_page_id = pager.allocate_overflow_chain(&value).unwrap();

        // Free the chain
        pager.free_overflow_chain(first_page_id).unwrap();

        // Next allocation should reuse one of the freed pages
        let _new_page = pager.allocate_overflow_page().unwrap();
    }

    #[test]
    fn test_empty_overflow_chain_rejected() {
        let mut pager = Pager::create_memory().unwrap();

        let result = pager.allocate_overflow_chain(&[]);
        assert!(result.is_err());
    }
}
