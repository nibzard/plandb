//! Page cache with LRU eviction and pinning support.
//!
//! Provides in-memory caching of pages to reduce I/O and improve performance.

use crate::error::{Error, Result};
use crate::page::PAGE_SIZE;
use crate::types::PageId;
use std::collections::HashMap;

/// Default cache capacity (number of pages)
const DEFAULT_MAX_PAGES: usize = 1024;

/// Default cache capacity (bytes)
const DEFAULT_MAX_BYTES: usize = 16 * 1024 * 1024; // 16MB

/// Cache entry representing a cached page
struct CacheEntry {
    /// Page data (owned by cache)
    data: Box<[u8; PAGE_SIZE]>,
    /// Pin count (number of active references)
    pin_count: usize,
    /// Last access timestamp (for LRU)
    last_access: u64,
}

/// Page cache with LRU eviction
pub struct PageCache {
    /// Map from page ID to cache entry
    entries: HashMap<u64, CacheEntry>,
    /// LRU access counter for timestamping
    access_counter: u64,
    /// Maximum number of pages
    max_pages: usize,
    /// Maximum memory usage in bytes
    max_bytes: usize,
    /// Current memory usage in bytes
    current_bytes: usize,
}

impl PageCache {
    /// Create a new page cache with default capacity
    pub fn new() -> Self {
        Self {
            entries: HashMap::new(),
            access_counter: 0,
            max_pages: DEFAULT_MAX_PAGES,
            max_bytes: DEFAULT_MAX_BYTES,
            current_bytes: 0,
        }
    }

    /// Create a new page cache with custom capacity
    pub fn with_capacity(max_pages: usize, max_bytes: usize) -> Self {
        Self {
            entries: HashMap::new(),
            access_counter: 0,
            max_pages,
            max_bytes,
            current_bytes: 0,
        }
    }

    /// Get a page from the cache
    ///
    /// Returns None if the page is not cached.
    /// If the page is found, increments the pin count and updates LRU.
    pub fn get(&mut self, page_id: PageId) -> Option<&[u8]> {
        let entry = self.entries.get_mut(&page_id.as_u64())?;

        // Update LRU timestamp and increment pin count
        self.access_counter += 1;
        entry.last_access = self.access_counter;
        entry.pin_count += 1;

        // Return borrowed reference to page data
        Some(&entry.data[..])
    }

    /// Insert a page into the cache
    ///
    /// If the page is already cached, updates the data.
    /// May evict unpinned pages if capacity exceeded.
    pub fn put(&mut self, page_id: PageId, data: &[u8]) -> Result<()> {
        // Validate data size
        if data.len() != PAGE_SIZE {
            return Err(Error::Validation(crate::error::ValidationError::InvalidHeaderSize {
                expected: PAGE_SIZE,
                actual: data.len(),
            }));
        }

        // Check if updating existing entry
        let is_update = self.entries.contains_key(&page_id.as_u64());

        // Calculate new memory usage
        let new_entry_size = if is_update {
            // Updating existing entry - size doesn't change
            0
        } else {
            // New entry - add page size
            PAGE_SIZE
        };

        // Evict if necessary
        if !is_update {
            self.evict_if_needed(new_entry_size)?;
        }

        // Update access counter
        self.access_counter += 1;

        // Create or update entry
        let mut boxed_data = Box::new([0u8; PAGE_SIZE]);
        boxed_data.copy_from_slice(data);

        let entry = CacheEntry {
            data: boxed_data,
            pin_count: 1, // Auto-pin on insert
            last_access: self.access_counter,
        };

        // Insert or update
        if is_update {
            // For update, maintain existing pin count but update data and timestamp
            if let Some(existing) = self.entries.get_mut(&page_id.as_u64()) {
                let old_pin_count = existing.pin_count;
                self.entries.insert(page_id.as_u64(), entry);
                let new_entry = self.entries.get_mut(&page_id.as_u64()).unwrap();
                new_entry.pin_count = old_pin_count;
            }
        } else {
            self.entries.insert(page_id.as_u64(), entry);
            self.current_bytes += new_entry_size;
        }

        Ok(())
    }

    /// Unpin a page, making it eligible for eviction
    ///
    /// Safe to call multiple times (pin count clamped to 0).
    pub fn unpin(&mut self, page_id: PageId) {
        if let Some(entry) = self.entries.get_mut(&page_id.as_u64()) {
            if entry.pin_count > 0 {
                entry.pin_count -= 1;
            }
        }
    }

    /// Remove a page from the cache
    ///
    /// Returns false if the page was not found or was pinned.
    pub fn remove(&mut self, page_id: PageId) -> bool {
        if let Some(entry) = self.entries.get(&page_id.as_u64()) {
            if entry.pin_count == 0 {
                self.entries.remove(&page_id.as_u64());
                self.current_bytes = self.current_bytes.saturating_sub(PAGE_SIZE);
                return true;
            }
        }
        false
    }

    /// Clear all unpinned pages from the cache
    pub fn clear(&mut self) {
        // Remove all unpinned entries
        self.entries.retain(|_id, entry| {
            if entry.pin_count > 0 {
                true
            } else {
                self.current_bytes = self.current_bytes.saturating_sub(PAGE_SIZE);
                false
            }
        });
    }

    /// Get cache statistics
    pub fn stats(&self) -> CacheStats {
        let pinned_count = self.entries.values().filter(|e| e.pin_count > 0).count();

        CacheStats {
            total_pages: self.entries.len(),
            pinned_pages: pinned_count,
            current_bytes: self.current_bytes,
            max_pages: self.max_pages,
            max_bytes: self.max_bytes,
        }
    }

    /// Check if a page is cached
    pub fn contains(&self, page_id: PageId) -> bool {
        self.entries.contains_key(&page_id.as_u64())
    }

    /// Get the number of pages in the cache
    pub fn len(&self) -> usize {
        self.entries.len()
    }

    /// Check if the cache is empty
    pub fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }

    /// Evict pages if capacity would be exceeded
    fn evict_if_needed(&mut self, needed_bytes: usize) -> Result<()> {
        // Check entry count limit
        while self.entries.len() >= self.max_pages {
            self.evict_one()?;
        }

        // Check byte limit
        while self.current_bytes + needed_bytes > self.max_bytes {
            self.evict_one()?;
        }

        Ok(())
    }

    /// Evict one unpinned page using LRU policy
    fn evict_one(&mut self) -> Result<()> {
        // Find LRU unpinned entry
        let mut lru_page_id = None;
        let mut lru_timestamp = None;

        for (page_id, entry) in &self.entries {
            if entry.pin_count == 0 {
                match lru_timestamp {
                    None => {
                        lru_timestamp = Some(entry.last_access);
                        lru_page_id = Some(*page_id);
                    }
                    Some(current_lru) if entry.last_access < current_lru => {
                        lru_timestamp = Some(entry.last_access);
                        lru_page_id = Some(*page_id);
                    }
                    _ => {}
                }
            }
        }

        // Evict if found
        if let Some(page_id) = lru_page_id {
            self.entries.remove(&page_id);
            self.current_bytes = self.current_bytes.saturating_sub(PAGE_SIZE);
            Ok(())
        } else {
            // All pages are pinned - cache may exceed capacity
            Err(Error::Validation(crate::error::ValidationError::Generic(
                "Cannot evict: all pages are pinned".to_string(),
            )))
        }
    }

    /// Get the pin count for a page
    pub fn pin_count(&self, page_id: PageId) -> usize {
        self.entries
            .get(&page_id.as_u64())
            .map(|e| e.pin_count)
            .unwrap_or(0)
    }
}

impl Default for PageCache {
    fn default() -> Self {
        Self::new()
    }
}

/// Cache statistics
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct CacheStats {
    /// Total number of pages in cache
    pub total_pages: usize,
    /// Number of pinned pages
    pub pinned_pages: usize,
    /// Current memory usage in bytes
    pub current_bytes: usize,
    /// Maximum number of pages
    pub max_pages: usize,
    /// Maximum memory usage in bytes
    pub max_bytes: usize,
}

impl CacheStats {
    /// Calculate cache utilization (0.0 to 1.0+)
    pub fn utilization(&self) -> f64 {
        if self.max_bytes == 0 {
            0.0
        } else {
            self.current_bytes as f64 / self.max_bytes as f64
        }
    }

    /// Calculate cache hit ratio potential (not actual hit tracking)
    pub fn unpinned_pages(&self) -> usize {
        self.total_pages.saturating_sub(self.pinned_pages)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn make_test_page(page_id: u64) -> Vec<u8> {
        vec![page_id as u8; PAGE_SIZE]
    }

    #[test]
    fn test_cache_new() {
        let cache = PageCache::new();
        assert!(cache.is_empty());
        assert_eq!(cache.len(), 0);
    }

    #[test]
    fn test_cache_put_get() {
        let mut cache = PageCache::new();

        let page_data = make_test_page(42);
        cache.put(PageId::new(42), &page_data).unwrap();

        assert!(cache.contains(PageId::new(42)));
        assert_eq!(cache.len(), 1);

        let cached = cache.get(PageId::new(42));
        assert!(cached.is_some());
        assert_eq!(cached.unwrap(), &page_data[..]);
    }

    #[test]
    fn test_cache_miss() {
        let mut cache = PageCache::new();

        let cached = cache.get(PageId::new(999));
        assert!(cached.is_none());
    }

    #[test]
    fn test_cache_unpin() {
        let mut cache = PageCache::new();

        let page_data = make_test_page(42);
        cache.put(PageId::new(42), &page_data).unwrap();

        // After put, page is pinned (pin count = 1)
        assert_eq!(cache.pin_count(PageId::new(42)), 1);

        // Get increments pin count
        cache.get(PageId::new(42));
        assert_eq!(cache.pin_count(PageId::new(42)), 2);

        // Unpin decrements
        cache.unpin(PageId::new(42));
        assert_eq!(cache.pin_count(PageId::new(42)), 1);

        // Second unpin
        cache.unpin(PageId::new(42));
        assert_eq!(cache.pin_count(PageId::new(42)), 0);

        // Extra unpins are safe (clamped to 0)
        cache.unpin(PageId::new(42));
        cache.unpin(PageId::new(42));
        assert_eq!(cache.pin_count(PageId::new(42)), 0);
    }

    #[test]
    fn test_cache_remove() {
        let mut cache = PageCache::new();

        let page_data = make_test_page(42);
        cache.put(PageId::new(42), &page_data).unwrap();

        // Can't remove pinned page
        assert!(!cache.remove(PageId::new(42)));

        // Unpin first
        cache.unpin(PageId::new(42));

        // Now can remove
        assert!(cache.remove(PageId::new(42)));
        assert!(!cache.contains(PageId::new(42)));

        // Removing non-existent page returns false
        assert!(!cache.remove(PageId::new(42)));
    }

    #[test]
    fn test_cache_clear() {
        let mut cache = PageCache::new();

        // Add some pages (pages start with pin_count = 1)
        for i in 0..5 {
            let page_data = make_test_page(i);
            cache.put(PageId::new(i), &page_data).unwrap();
        }

        assert_eq!(cache.len(), 5);

        // Unpin all pages except page 2
        for i in 0..5 {
            if i != 2 {
                cache.unpin(PageId::new(i));
            }
        }

        // Clear should remove unpinned pages only
        cache.clear();

        // Only page 2 should remain (still pinned)
        assert_eq!(cache.len(), 1);
        assert!(cache.contains(PageId::new(2)));
    }

    #[test]
    fn test_cache_stats() {
        let mut cache = PageCache::new();

        let stats = cache.stats();
        assert_eq!(stats.total_pages, 0);
        assert_eq!(stats.pinned_pages, 0);
        assert_eq!(stats.current_bytes, 0);

        // Add some pages (pages start with pin_count = 1, so all are pinned)
        for i in 0..3 {
            let page_data = make_test_page(i);
            cache.put(PageId::new(i), &page_data).unwrap();
        }

        let stats = cache.stats();
        assert_eq!(stats.total_pages, 3);
        assert_eq!(stats.pinned_pages, 3); // All pages are pinned initially
        assert_eq!(stats.current_bytes, PAGE_SIZE * 3);

        // Unpin one page
        cache.unpin(PageId::new(1));

        let stats = cache.stats();
        assert_eq!(stats.pinned_pages, 2);
    }

    #[test]
    fn test_cache_lru_eviction() {
        // Create cache with very small capacity
        let mut cache = PageCache::with_capacity(3, PAGE_SIZE * 3);

        // Fill cache
        for i in 0..3 {
            let page_data = make_test_page(i);
            cache.put(PageId::new(i), &page_data).unwrap();
        }

        assert_eq!(cache.len(), 3);

        // Unpin all pages
        for i in 0..3 {
            cache.unpin(PageId::new(i));
        }

        // Access page 0 to make it more recently used
        cache.get(PageId::new(0));
        cache.unpin(PageId::new(0));

        // Add page 3 - should evict least recently used (page 1 or 2)
        let page_data = make_test_page(3);
        cache.put(PageId::new(3), &page_data).unwrap();

        // Cache should still have 3 pages
        assert_eq!(cache.len(), 3);

        // Page 0 should still be there (recently used)
        assert!(cache.contains(PageId::new(0)));
        assert!(cache.contains(PageId::new(3)));
    }

    #[test]
    fn test_pinned_pages_not_evicted() {
        // Create cache with small capacity
        let mut cache = PageCache::with_capacity(2, PAGE_SIZE * 2);

        // Add and pin page 0
        let page_data = make_test_page(0);
        cache.put(PageId::new(0), &page_data).unwrap();
        // Don't unpin - keeps it pinned

        // Try to add more pages than capacity
        for i in 1..5 {
            let page_data = make_test_page(i);
            cache.put(PageId::new(i), &page_data).unwrap();
            cache.unpin(PageId::new(i));
        }

        // Page 0 should still be there (pinned)
        assert!(cache.contains(PageId::new(0)));
        // Cache may exceed capacity due to pinned pages
    }

    #[test]
    fn test_cache_update() {
        let mut cache = PageCache::new();

        let page_data1 = make_test_page(42);
        cache.put(PageId::new(42), &page_data1).unwrap();
        cache.unpin(PageId::new(42));

        let page_data2 = vec![0xFFu8; PAGE_SIZE];
        cache.put(PageId::new(42), &page_data2).unwrap();

        // Should have updated data
        let cached = cache.get(PageId::new(42)).unwrap();
        assert_eq!(cached[0], 0xFF);
    }

    #[test]
    fn test_cache_with_capacity() {
        let cache = PageCache::with_capacity(100, PAGE_SIZE * 100);

        assert_eq!(cache.stats().max_pages, 100);
        assert_eq!(cache.stats().max_bytes, PAGE_SIZE * 100);
    }

    #[test]
    fn test_cache_utilization() {
        let mut cache = PageCache::with_capacity(10, PAGE_SIZE * 10);

        let stats = cache.stats();
        assert_eq!(stats.utilization(), 0.0);

        // Fill half the cache
        for i in 0..5 {
            let page_data = make_test_page(i);
            cache.put(PageId::new(i), &page_data).unwrap();
        }

        let stats = cache.stats();
        assert_eq!(stats.utilization(), 0.5);
    }

    #[test]
    fn test_wrong_buffer_size() {
        let mut cache = PageCache::new();

        let wrong_size = vec![0u8; PAGE_SIZE / 2];
        let result = cache.put(PageId::new(1), &wrong_size);

        assert!(result.is_err());
    }
}
