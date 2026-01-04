//! Page allocator for free list management and page allocation.
//!
//! Manages free page tracking, page allocation, and free list rebuilding.

use crate::error::{Error, Result, StorageError};
use crate::types::PageId;
use std::sync::atomic::{AtomicU64, Ordering};

/// Page allocator - manages free pages and allocation
pub struct PageAllocator {
    /// Free pages available for reuse (sorted ascending)
    free_pages: Vec<PageId>,
    /// Highest page ID ever allocated
    last_allocated_page: AtomicU64,
}

impl PageAllocator {
    /// Create a new page allocator
    pub fn new() -> Self {
        Self {
            free_pages: Vec::new(),
            last_allocated_page: AtomicU64::new(2), // Start at page 2 (after meta pages)
        }
    }

    /// Allocate a new page, reusing freed pages if available
    ///
    /// Returns the allocated page ID. If the free list has entries,
    /// reuses the lowest page ID. Otherwise, extends the file.
    pub fn allocate_page(&mut self) -> Result<PageId> {
        // Fast path: reuse from free list
        if !self.free_pages.is_empty() {
            // Free list is sorted, so first element is lowest ID
            let page_id = self.free_pages.remove(0);
            return Ok(page_id);
        }

        // Slow path: extend file
        let new_id = self.last_allocated_page.fetch_add(1, Ordering::AcqRel);
        Ok(PageId::new(new_id))
    }

    /// Free a page, adding it to the free list for reuse
    ///
    /// The page_id is inserted into the free list in sorted order.
    /// Returns an error if attempting to free a meta page (0 or 1).
    pub fn free_page(&mut self, page_id: PageId) -> Result<()> {
        // Prevent freeing meta pages
        if page_id.is_meta_page() {
            return Err(Error::Storage(StorageError::Pager(
                format!("Cannot free meta page {}", page_id.as_u64()),
            )));
        }

        // Find insertion point to maintain sorted order
        let pos = self
            .free_pages
            .binary_search(&page_id)
            .unwrap_or_else(|pos| pos);

        // Insert at sorted position
        self.free_pages.insert(pos, page_id);

        Ok(())
    }

    /// Get the number of free pages available
    pub fn free_page_count(&self) -> usize {
        self.free_pages.len()
    }

    /// Get the highest page ID ever allocated
    pub fn last_allocated_page_id(&self) -> PageId {
        let last = self.last_allocated_page.load(Ordering::Acquire);
        if last > 0 {
            PageId::new(last - 1)
        } else {
            PageId::new(0)
        }
    }

    /// Get the total number of pages (allocated + potentially free)
    pub fn total_pages(&self) -> u64 {
        self.last_allocated_page.load(Ordering::Acquire)
    }

    /// Rebuild the free list by scanning the B+tree
    ///
    /// This is a placeholder for the full implementation.
    /// In the complete implementation, this would traverse the B+tree
    /// to identify all pages in use and mark the rest as free.
    ///
    /// For now, this does nothing since we don't have B+tree integration yet.
    pub fn rebuild_freelist(&mut self, _storage: &crate::pager::storage::Storage) -> Result<()> {
        // TODO: Implement B+tree traversal to rebuild free list
        // This requires:
        // 1. Get total pages from storage
        // 2. Allocate boolean array marking page usage
        // 3. Mark meta pages as in use
        // 4. Traverse B+tree from root, marking reachable pages
        // 5. Build free list from unmarked pages
        Ok(())
    }

    /// Get iterator over free pages (sorted)
    pub fn free_pages_iter(&self) -> impl Iterator<Item = PageId> + '_ {
        self.free_pages.iter().copied()
    }

    /// Check if a page is in the free list
    pub fn is_free(&self, page_id: PageId) -> bool {
        self.free_pages.binary_search(&page_id).is_ok()
    }

    /// Clear all free pages (for testing)
    #[cfg(test)]
    pub fn clear(&mut self) {
        self.free_pages.clear();
    }
}

impl Default for PageAllocator {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_allocator_new() {
        let allocator = PageAllocator::new();
        assert_eq!(allocator.free_page_count(), 0);
        assert_eq!(allocator.last_allocated_page_id().as_u64(), 1); // 2 - 1 = 1
    }

    #[test]
    fn test_allocate_extends_file() {
        let mut allocator = PageAllocator::new();

        // Allocate first page (should be page 2, after meta pages)
        let page1 = allocator.allocate_page().unwrap();
        assert_eq!(page1.as_u64(), 2);

        // Allocate second page (should be page 3)
        let page2 = allocator.allocate_page().unwrap();
        assert_eq!(page2.as_u64(), 3);

        // Third page should be 4
        let page3 = allocator.allocate_page().unwrap();
        assert_eq!(page3.as_u64(), 4);
    }

    #[test]
    fn test_allocate_reuses_freed_page() {
        let mut allocator = PageAllocator::new();

        // Allocate pages 2, 3, 4
        let page2 = allocator.allocate_page().unwrap();
        let page3 = allocator.allocate_page().unwrap();
        let page4 = allocator.allocate_page().unwrap();

        assert_eq!(page2.as_u64(), 2);
        assert_eq!(page3.as_u64(), 3);
        assert_eq!(page4.as_u64(), 4);

        // Free page 3
        allocator.free_page(page3).unwrap();

        // Next allocation should reuse page 3 (lowest free page)
        let reused = allocator.allocate_page().unwrap();
        assert_eq!(reused.as_u64(), 3);

        // Next allocation should extend to page 5
        let page5 = allocator.allocate_page().unwrap();
        assert_eq!(page5.as_u64(), 5);
    }

    #[test]
    fn test_free_page_sorted() {
        let mut allocator = PageAllocator::new();

        // Allocate some pages
        let _ = allocator.allocate_page().unwrap(); // 2
        let _ = allocator.allocate_page().unwrap(); // 3
        let _ = allocator.allocate_page().unwrap(); // 4
        let _ = allocator.allocate_page().unwrap(); // 5
        let _ = allocator.allocate_page().unwrap(); // 6

        // Free in non-sorted order
        allocator.free_page(PageId::new(5)).unwrap();
        allocator.free_page(PageId::new(3)).unwrap();
        allocator.free_page(PageId::new(4)).unwrap();

        // Free list should be sorted
        let free_pages: Vec<_> = allocator.free_pages_iter().collect();
        assert_eq!(free_pages, vec![PageId::new(3), PageId::new(4), PageId::new(5)]);

        // Allocations should use lowest ID first
        assert_eq!(allocator.allocate_page().unwrap().as_u64(), 3);
        assert_eq!(allocator.allocate_page().unwrap().as_u64(), 4);
        assert_eq!(allocator.allocate_page().unwrap().as_u64(), 5);
    }

    #[test]
    fn test_free_meta_page_rejected() {
        let mut allocator = PageAllocator::new();

        // Should not be able to free meta pages
        let result = allocator.free_page(PageId::META_A);
        assert!(result.is_err());

        let result = allocator.free_page(PageId::META_B);
        assert!(result.is_err());
    }

    #[test]
    fn test_is_free() {
        let mut allocator = PageAllocator::new();

        // Allocate and free page 5
        let _ = allocator.allocate_page().unwrap(); // 2
        let _ = allocator.allocate_page().unwrap(); // 3
        let _ = allocator.allocate_page().unwrap(); // 4
        let page5 = allocator.allocate_page().unwrap(); // 5

        allocator.free_page(page5).unwrap();

        // Page 5 should be in free list
        assert!(allocator.is_free(page5));

        // Page 4 should not be in free list
        assert!(!allocator.is_free(PageId::new(4)));
    }

    #[test]
    fn test_free_page_count() {
        let mut allocator = PageAllocator::new();

        assert_eq!(allocator.free_page_count(), 0);

        // Allocate pages
        let _p2 = allocator.allocate_page().unwrap();
        let _p3 = allocator.allocate_page().unwrap();
        let _p4 = allocator.allocate_page().unwrap();

        assert_eq!(allocator.free_page_count(), 0);

        // Free two pages
        allocator.free_page(_p3).unwrap();
        allocator.free_page(_p4).unwrap();

        assert_eq!(allocator.free_page_count(), 2);

        // Allocate one back
        allocator.allocate_page().unwrap();

        assert_eq!(allocator.free_page_count(), 1);
    }

    #[test]
    fn test_last_allocated_page_id() {
        let mut allocator = PageAllocator::new();

        assert_eq!(allocator.last_allocated_page_id().as_u64(), 1);

        allocator.allocate_page().unwrap();
        assert_eq!(allocator.last_allocated_page_id().as_u64(), 2);

        allocator.allocate_page().unwrap();
        assert_eq!(allocator.last_allocated_page_id().as_u64(), 3);
    }

    #[test]
    fn test_total_pages() {
        let mut allocator = PageAllocator::new();

        assert_eq!(allocator.total_pages(), 2);

        allocator.allocate_page().unwrap();
        assert_eq!(allocator.total_pages(), 3);

        allocator.allocate_page().unwrap();
        assert_eq!(allocator.total_pages(), 4);

        // Freeing doesn't change total
        allocator.free_page(PageId::new(2)).unwrap();
        assert_eq!(allocator.total_pages(), 4);
    }

    #[test]
    fn test_free_and_reuse_cycle() {
        let mut allocator = PageAllocator::new();

        // Allocate pages
        let p2 = allocator.allocate_page().unwrap();
        let p3 = allocator.allocate_page().unwrap();
        let p4 = allocator.allocate_page().unwrap();

        // Free them all
        allocator.free_page(p2).unwrap();
        allocator.free_page(p3).unwrap();
        allocator.free_page(p4).unwrap();

        // Reallocate in different order
        let reused2 = allocator.allocate_page().unwrap();
        assert_eq!(reused2.as_u64(), 2);

        let reused3 = allocator.allocate_page().unwrap();
        assert_eq!(reused3.as_u64(), 3);

        let reused4 = allocator.allocate_page().unwrap();
        assert_eq!(reused4.as_u64(), 4);

        // Next should extend
        let p5 = allocator.allocate_page().unwrap();
        assert_eq!(p5.as_u64(), 5);
    }

    #[test]
    fn test_clear() {
        let mut allocator = PageAllocator::new();

        // Allocate and free some pages
        let p2 = allocator.allocate_page().unwrap();
        let _p3 = allocator.allocate_page().unwrap();
        allocator.free_page(p2).unwrap();

        assert_eq!(allocator.free_page_count(), 1);

        allocator.clear();

        assert_eq!(allocator.free_page_count(), 0);
        // last_allocated_page is not reset
        assert_eq!(allocator.last_allocated_page_id().as_u64(), 3);
    }
}
