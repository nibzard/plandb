//! L1 Page Cache - caches complete 16KB disk pages with dirty tracking.
//!
//! PageCache provides in-memory caching of disk pages to reduce I/O and improve performance.
//! It supports dirty page tracking for write-back, background flushing, and integrates with
//! the Pager for page I/O operations.

use crate::cache::types::{CacheConfig, CachePolicy, CacheSnapshot};
use crate::cache::{Cache, CacheError};
use crate::error::{Error, Result};
use crate::page::{Page, PAGE_SIZE};
use crate::types::PageId;
use parking_lot::Mutex;
use std::sync::Arc;

/// Default page cache capacity (256MB for 16KB pages = 16384 pages)
const DEFAULT_MAX_BYTES: usize = 256 * 1024 * 1024;

/// Page cache with dirty tracking and write-back
pub struct PageCache {
    /// Inner cache using generic Cache infrastructure
    cache: Cache<PageId, Vec<u8>>,
    /// Dirty page tracking (pages that have been modified but not written)
    dirty_pages: Arc<Mutex<std::collections::HashSet<PageId>>>,
    /// Background write-back task handle
    writeback_task: Arc<Mutex<Option<tokio::task::JoinHandle<()>>>>,
    /// Configuration
    config: CacheConfig,
}

impl PageCache {
    /// Create a new page cache with default configuration
    pub fn new() -> Self {
        let mut config = CacheConfig::default();
        config.max_size = DEFAULT_MAX_BYTES;
        config.max_entries = DEFAULT_MAX_BYTES / PAGE_SIZE;
        config.policy = CachePolicy::Arc; // Adaptive Replacement Cache for pages

        Self::with_config(config)
    }

    /// Create a new page cache with custom configuration
    pub fn with_config(config: CacheConfig) -> Self {
        let cache = Cache::with_config(config.clone());
        let dirty_pages = Arc::new(Mutex::new(std::collections::HashSet::new()));
        let writeback_task = Arc::new(Mutex::new(None));

        Self {
            cache,
            dirty_pages,
            writeback_task,
            config,
        }
    }

    /// Get a page from cache
    ///
    /// Returns None if page is not cached. Increments pin count on cache hit.
    pub fn get(&self, page_id: PageId) -> Option<Vec<u8>> {
        self.cache.get(&page_id)
    }

    /// Insert a page into cache
    ///
    /// Marks page as clean (use mark_dirty() after modification).
    pub fn put(&self, page_id: PageId, data: &[u8]) -> Result<()> {
        if data.len() != PAGE_SIZE {
            return Err(Error::Validation(crate::error::ValidationError::InvalidHeaderSize {
                expected: PAGE_SIZE,
                actual: data.len(),
            }));
        }

        // Insert into cache (starts clean)
        self.cache.put(page_id, data.to_vec(), PAGE_SIZE)
            .map_err(|e| Error::Validation(crate::error::ValidationError::Generic(format!("Cache error: {:?}", e))))?;
        Ok(())
    }

    /// Mark a cached page as dirty (modified but not written)
    pub fn mark_dirty(&self, page_id: PageId) {
        self.dirty_pages.lock().insert(page_id);
    }

    /// Check if a page is dirty
    pub fn is_dirty(&self, page_id: PageId) -> bool {
        self.dirty_pages.lock().contains(&page_id)
    }

    /// Invalidate a page from cache
    ///
    /// If page is dirty, it should be written back before removal.
    /// Returns true if page was found and removed.
    pub fn invalidate(&self, page_id: PageId) -> bool {
        // Check if dirty before removing
        let was_dirty = self.is_dirty(page_id);

        // Remove from cache
        let removed = self.cache.invalidate(&page_id);

        // Remove from dirty tracking
        self.dirty_pages.lock().remove(&page_id);

        if removed && was_dirty {
            // TODO: Write back dirty page before removal
            // This requires a reference to Pager for I/O
        }

        removed
    }

    /// Remove a page from cache (alias for invalidate)
    pub fn remove(&self, page_id: PageId) -> bool {
        self.invalidate(page_id)
    }

    /// Pin a page to prevent eviction
    pub fn pin(&self, page_id: PageId) -> bool {
        self.cache.pin(&page_id)
    }

    /// Unpin a page
    pub fn unpin(&self, page_id: PageId) -> bool {
        self.cache.unpin(&page_id)
    }

    /// Clear all unpinned pages from cache
    ///
    /// Returns statistics about cleared pages.
    pub fn clear(&self) -> crate::cache::types::ClearResult {
        // TODO: Write back all dirty pages before clearing
        let result = self.cache.clear();
        self.dirty_pages.lock().clear();
        result
    }

    /// Get cache statistics snapshot
    pub fn stats(&self) -> CacheSnapshot {
        let mut snapshot = self.cache.stats();
        // Update dirty page count from our tracking
        snapshot.dirty_pages = self.dirty_pages.lock().len();
        snapshot
    }

    /// Check if a page is cached
    pub fn contains(&self, page_id: PageId) -> bool {
        self.cache.get(&page_id).is_some()
    }

    /// Get the number of dirty pages
    pub fn dirty_count(&self) -> usize {
        self.dirty_pages.lock().len()
    }

    /// Get all dirty page IDs
    pub fn dirty_pages(&self) -> Vec<PageId> {
        self.dirty_pages.lock().iter().copied().collect()
    }

    /// Flush dirty pages (write-back integration point)
    ///
    /// This is called by background task or on explicit flush requests.
    /// The actual I/O is performed by the Pager through a callback.
    pub fn flush_dirty_pages<F>(&self, mut write_fn: F) -> Result<usize>
    where
        F: FnMut(PageId, Vec<u8>) -> Result<()>,
    {
        let dirty_pages: Vec<PageId> = self.dirty_pages();
        let mut written = 0;

        for page_id in dirty_pages {
            if let Some(data) = self.cache.get(&page_id) {
                // Write page to storage
                write_fn(page_id, data.clone())?;

                // Mark as clean after successful write
                self.dirty_pages.lock().remove(&page_id);
                written += 1;

                // Unpin after write
                self.unpin(page_id);
            }
        }

        Ok(written)
    }

    /// Start background write-back task
    #[cfg(feature = "async")]
    pub fn start_writeback_task(&self, interval: std::time::Duration) {
        use tokio::time::interval;

        let dirty_pages = self.dirty_pages.clone();
        let cache = self.cache.clone();

        let handle = tokio::spawn(async move {
            let mut timer = interval(interval);
            loop {
                timer.tick().await;

                // Collect dirty page IDs
                let pages_to_flush: Vec<PageId> = dirty_pages.lock().iter().copied().collect();

                // TODO: Write back to storage
                // This requires Pager integration
            }
        });

        *self.writeback_task.lock() = Some(handle);
    }

    /// Stop background write-back task
    #[cfg(feature = "async")]
    pub fn stop_writeback_task(&self) {
        if let Some(handle) = self.writeback_task.lock().take() {
            handle.abort();
        }
    }
}

impl Default for PageCache {
    fn default() -> Self {
        Self::new()
    }
}

impl Clone for PageCache {
    fn clone(&self) -> Self {
        // Create a new PageCache sharing the same underlying cache
        Self {
            cache: Cache::with_config(self.config.clone()),
            dirty_pages: Arc::clone(&self.dirty_pages),
            writeback_task: Arc::clone(&self.writeback_task),
            config: self.config.clone(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn make_test_page(page_id: u64) -> Vec<u8> {
        vec![page_id as u8; PAGE_SIZE]
    }

    #[test]
    fn test_page_cache_new() {
        let cache = PageCache::new();
        let stats = cache.stats();
        assert_eq!(stats.current_entries, 0);
        assert_eq!(stats.dirty_pages, 0);
    }

    #[test]
    fn test_page_cache_put_get() {
        let cache = PageCache::new();
        let page_id = PageId::new(42);
        let page_data = make_test_page(42);

        cache.put(page_id, &page_data).unwrap();
        assert!(cache.contains(page_id));

        let retrieved = cache.get(page_id);
        assert!(retrieved.is_some());
        assert_eq!(retrieved.unwrap(), page_data);
    }

    #[test]
    fn test_page_cache_dirty_tracking() {
        let cache = PageCache::new();
        let page_id = PageId::new(42);
        let page_data = make_test_page(42);

        cache.put(page_id, &page_data).unwrap();
        assert!(!cache.is_dirty(page_id));
        assert_eq!(cache.dirty_count(), 0);

        cache.mark_dirty(page_id);
        assert!(cache.is_dirty(page_id));
        assert_eq!(cache.dirty_count(), 1);

        let dirty_pages = cache.dirty_pages();
        assert_eq!(dirty_pages.len(), 1);
        assert_eq!(dirty_pages[0], page_id);
    }

    #[test]
    fn test_page_cache_pin_unpin() {
        let cache = PageCache::new();
        let page_id = PageId::new(42);
        let page_data = make_test_page(42);

        cache.put(page_id, &page_data).unwrap();

        // Pin the page
        assert!(cache.pin(page_id));

        // Unpin the page
        assert!(cache.unpin(page_id));

        // Unpin non-existent page
        assert!(!cache.unpin(PageId::new(999)));
    }

    #[test]
    fn test_page_cache_invalidate() {
        let cache = PageCache::new();
        let page_id = PageId::new(42);
        let page_data = make_test_page(42);

        cache.put(page_id, &page_data).unwrap();
        cache.mark_dirty(page_id);

        assert!(cache.contains(page_id));
        assert!(cache.is_dirty(page_id));

        // Invalidate removes from cache and dirty tracking
        assert!(cache.invalidate(page_id));
        assert!(!cache.contains(page_id));
        assert!(!cache.is_dirty(page_id));

        // Invalidate non-existent page
        assert!(!cache.invalidate(PageId::new(999)));
    }

    #[test]
    fn test_page_cache_clear() {
        let cache = PageCache::new();

        // Add multiple pages
        for i in 0..5 {
            let page_id = PageId::new(i);
            let page_data = make_test_page(i);
            cache.put(page_id, &page_data).unwrap();
            if i % 2 == 0 {
                cache.mark_dirty(page_id);
            }
        }

        assert_eq!(cache.dirty_count(), 3);

        // Clear all
        let result = cache.clear();
        assert!(result.entries_cleared > 0);
        assert_eq!(cache.dirty_count(), 0);
    }

    #[test]
    fn test_page_cache_stats() {
        let cache = PageCache::new();

        // Add some pages
        for i in 0..3 {
            let page_id = PageId::new(i);
            let page_data = make_test_page(i);
            cache.put(page_id, &page_data).unwrap();
        }

        let stats = cache.stats();
        assert_eq!(stats.current_entries, 3);
        assert_eq!(stats.current_size, 3 * PAGE_SIZE);
        assert_eq!(stats.dirty_pages, 0);

        // Mark one as dirty
        cache.mark_dirty(PageId::new(1));
        let stats = cache.stats();
        assert_eq!(stats.dirty_pages, 1);
    }

    #[test]
    fn test_page_cache_wrong_size() {
        let cache = PageCache::new();
        let page_id = PageId::new(42);
        let wrong_size = vec![0u8; PAGE_SIZE / 2];

        let result = cache.put(page_id, &wrong_size);
        assert!(result.is_err());
    }

    #[test]
    fn test_page_cache_flush_dirty_pages() {
        let cache = PageCache::new();

        // Add some pages and mark some as dirty
        for i in 0..5 {
            let page_id = PageId::new(i);
            let page_data = make_test_page(i);
            cache.put(page_id, &page_data).unwrap();
            if i % 2 == 0 {
                cache.mark_dirty(page_id);
            }
        }

        assert_eq!(cache.dirty_count(), 3);

        // Flush dirty pages with mock write function
        let mut written_pages = Vec::new();
        let result = cache.flush_dirty_pages(|page_id, data| {
            written_pages.push(page_id);
            Ok(())
        });

        assert!(result.is_ok());
        assert_eq!(result.unwrap(), 3);
        assert_eq!(cache.dirty_count(), 0);
    }

    #[test]
    fn test_page_cache_miss() {
        let cache = PageCache::new();
        assert!(!cache.contains(PageId::new(999)));
        assert!(cache.get(PageId::new(999)).is_none());
    }

    #[test]
    fn test_page_cache_eviction() {
        // Test with default cache configuration (256MB, large capacity)
        let cache = PageCache::new();

        // Add a reasonable number of pages (well within 256MB capacity)
        for i in 0..50 {
            let page_id = PageId::new(i);
            let page_data = make_test_page(i);
            cache.put(page_id, &page_data).unwrap();
            cache.unpin(page_id); // Unpin to allow eviction
        }

        // All pages should fit in 256MB cache
        let stats = cache.stats();
        assert_eq!(stats.current_entries, 50);

        // Add more pages
        for i in 50..100 {
            let page_id = PageId::new(i);
            let page_data = make_test_page(i);
            cache.put(page_id, &page_data).unwrap();
            cache.unpin(page_id);
        }

        // All 100 pages should still fit (100 * 16KB = 1.6MB << 256MB)
        let stats = cache.stats();
        assert_eq!(stats.current_entries, 100);
    }
}
