//! B+Tree Range Scan Operations
//!
//! Iterator for efficient range queries over leaf nodes.

use crate::{types::{Lsn, PageId}, Result};
use std::vec::IntoIter;

/// Scan direction
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ScanDirection {
    /// Forward (ascending)
    Forward,
    /// Backward (descending)
    Backward,
}

/// Scan result item
#[derive(Debug, Clone, PartialEq)]
pub struct ScanItem {
    /// Key bytes
    pub key: Vec<u8>,
    /// Value bytes
    pub value: Vec<u8>,
    /// Log sequence number
    pub lsn: Lsn,
}

impl ScanItem {
    /// Create a new scan item
    pub fn new(key: Vec<u8>, value: Vec<u8>, lsn: Lsn) -> Self {
        Self { key, value, lsn }
    }
}

/// Range scan iterator over B+Tree
#[derive(Debug)]
pub struct ScanIter {
    /// Current position in entries
    entries: IntoIter<ScanItem>,
    /// End key (exclusive), if any
    end_key: Option<Vec<u8>>,
    /// Snapshot LSN for version resolution
    snapshot_lsn: Lsn,
    /// Scan direction
    direction: ScanDirection,
}

impl ScanIter {
    /// Create a new scan iterator
    pub fn new(
        entries: Vec<ScanItem>,
        end_key: Option<Vec<u8>>,
        snapshot_lsn: Lsn,
        direction: ScanDirection,
    ) -> Self {
        Self {
            entries: entries.into_iter(),
            end_key,
            snapshot_lsn,
            direction,
        }
    }

    /// Create a forward scan
    pub fn forward(entries: Vec<ScanItem>, end_key: Option<Vec<u8>>, snapshot_lsn: Lsn) -> Self {
        Self::new(entries, end_key, snapshot_lsn, ScanDirection::Forward)
    }

    /// Create a backward scan
    pub fn backward(entries: Vec<ScanItem>, start_key: Option<Vec<u8>>, snapshot_lsn: Lsn) -> Self {
        // Reverse entries for backward scan
        let mut entries = entries;
        entries.reverse();
        Self::new(entries, start_key, snapshot_lsn, ScanDirection::Backward)
    }

    /// Check if we should continue iteration
    fn should_continue(&self, key: &[u8]) -> bool {
        match &self.end_key {
            None => true,
            Some(end) => match self.direction {
                ScanDirection::Forward => key < end.as_slice(),
                ScanDirection::Backward => key > end.as_slice(),
            },
        }
    }
}

impl Iterator for ScanIter {
    type Item = ScanItem;

    fn next(&mut self) -> Option<Self::Item> {
        loop {
            let item = self.entries.next()?;

            if self.should_continue(&item.key) && item.lsn <= self.snapshot_lsn {
                return Some(item);
            }

            // Skip items that don't match criteria
            if !self.should_continue(&item.key) {
                return None;
            }
        }
    }
}

/// Scan state for multi-page scans
#[derive(Debug, Clone)]
pub struct ScanState {
    /// Current page ID
    pub current_page: PageId,
    /// Current entry index within page
    pub current_index: usize,
    /// Start key (inclusive), if any
    pub start_key: Option<Vec<u8>>,
    /// End key (exclusive), if any
    pub end_key: Option<Vec<u8>>,
    /// Snapshot LSN
    pub snapshot_lsn: Lsn,
    /// Scan direction
    pub direction: ScanDirection,
    /// Whether scan has started
    pub started: bool,
    /// Whether scan has ended
    pub ended: bool,
}

impl ScanState {
    /// Create a new scan state
    pub fn new(
        start_page: PageId,
        start_key: Option<Vec<u8>>,
        end_key: Option<Vec<u8>>,
        snapshot_lsn: Lsn,
        direction: ScanDirection,
    ) -> Self {
        Self {
            current_page: start_page,
            current_index: 0,
            start_key,
            end_key,
            snapshot_lsn,
            direction,
            started: false,
            ended: false,
        }
    }

    /// Create a forward scan state
    pub fn forward(
        start_page: PageId,
        start_key: Option<Vec<u8>>,
        end_key: Option<Vec<u8>>,
        snapshot_lsn: Lsn,
    ) -> Self {
        Self::new(start_page, start_key, end_key, snapshot_lsn, ScanDirection::Forward)
    }

    /// Create a backward scan state
    pub fn backward(
        start_page: PageId,
        start_key: Option<Vec<u8>>,
        end_key: Option<Vec<u8>>,
        snapshot_lsn: Lsn,
    ) -> Self {
        Self::new(start_page, start_key, end_key, snapshot_lsn, ScanDirection::Backward)
    }

    /// Move to next page
    pub fn advance_page(&mut self, next_page: PageId) {
        self.current_page = next_page;
        self.current_index = 0;
    }

    /// Move to previous page (for backward scans)
    pub fn retreat_page(&mut self, prev_page: PageId) {
        self.current_page = prev_page;
        self.current_index = usize::MAX; // Will be adjusted on first access
    }

    /// Mark scan as started
    pub fn mark_started(&mut self) {
        self.started = true;
    }

    /// Mark scan as ended
    pub fn mark_ended(&mut self) {
        self.ended = true;
    }

    /// Check if scan is active
    pub fn is_active(&self) -> bool {
        self.started && !self.ended
    }

    /// Check if key is within scan range
    pub fn is_in_range(&self, key: &[u8]) -> bool {
        // Check start key (for forward scan)
        if let Some(start) = &self.start_key {
            if self.direction == ScanDirection::Forward && key < start.as_slice() {
                return false;
            }
            if self.direction == ScanDirection::Backward && key > start.as_slice() {
                return false;
            }
        }

        // Check end key
        if let Some(end) = &self.end_key {
            if self.direction == ScanDirection::Forward && key >= end.as_slice() {
                return false;
            }
            if self.direction == ScanDirection::Backward && key <= end.as_slice() {
                return false;
            }
        }

        true
    }
}

/// Filter scan results by LSN
pub fn filter_by_snapshot(items: Vec<ScanItem>, snapshot_lsn: Lsn) -> Vec<ScanItem> {
    items.into_iter()
        .filter(|item| item.lsn <= snapshot_lsn)
        .collect()
}

/// Merge multiple sorted item vectors into one sorted vector
pub fn merge_sorted_items(mut item_vectors: Vec<Vec<ScanItem>>) -> Vec<ScanItem> {
    if item_vectors.is_empty() {
        return Vec::new();
    }

    if item_vectors.len() == 1 {
        return item_vectors.pop().unwrap();
    }

    // Simple merge for now - could be optimized with heap
    let mut result = Vec::new();
    let mut iterators: Vec<_> = item_vectors
        .into_iter()
        .map(|v| v.into_iter())
        .collect();

    loop {
        // Find smallest next item
        let mut smallest_index = None;
        let mut smallest_key = None;

        for (i, iter) in iterators.iter().enumerate() {
            if let Some(item) = iter.as_slice().first() {
                if smallest_key.is_none() || item.key < smallest_key.unwrap() {
                    smallest_key = Some(&item.key);
                    smallest_index = Some(i);
                }
            }
        }

        match smallest_index {
            Some(index) => {
                if let Some(item) = iterators[index].next() {
                    result.push(item);
                }
            }
            None => break,
        }
    }

    result
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_scan_iter_forward() {
        let items = vec![
            ScanItem::new(b"key1".to_vec(), b"value1".to_vec(), Lsn::from(100)),
            ScanItem::new(b"key2".to_vec(), b"value2".to_vec(), Lsn::from(200)),
            ScanItem::new(b"key3".to_vec(), b"value3".to_vec(), Lsn::from(300)),
        ];

        let mut iter = ScanIter::forward(items, Some(b"key3".to_vec()), Lsn::from(1000));

        assert!(iter.next().is_some()); // key1
        assert!(iter.next().is_some()); // key2
        assert!(iter.next().is_some()); // key3
        assert!(iter.next().is_none()); // end
    }

    #[test]
    fn test_scan_iter_backward() {
        let items = vec![
            ScanItem::new(b"key1".to_vec(), b"value1".to_vec(), Lsn::from(100)),
            ScanItem::new(b"key2".to_vec(), b"value2".to_vec(), Lsn::from(200)),
            ScanItem::new(b"key3".to_vec(), b"value3".to_vec(), Lsn::from(300)),
        ];

        let mut iter = ScanIter::backward(items, Some(b"key1".to_vec()), Lsn::from(1000));

        assert!(iter.next().is_some()); // key3
        assert!(iter.next().is_some()); // key2
        assert!(iter.next().is_some()); // key1
        assert!(iter.next().is_none()); // end
    }

    #[test]
    fn test_scan_iter_snapshot_filtering() {
        let items = vec![
            ScanItem::new(b"key1".to_vec(), b"value1".to_vec(), Lsn::from(100)),
            ScanItem::new(b"key2".to_vec(), b"value2".to_vec(), Lsn::from(200)),
            ScanItem::new(b"key3".to_vec(), b"value3".to_vec(), Lsn::from(300)),
        ];

        // Snapshot at LSN 250 should only see items with LSN <= 250
        let mut iter = ScanIter::forward(items.clone(), None, Lsn::from(250));

        assert!(iter.next().is_some()); // key1 (LSN 100)
        assert!(iter.next().is_some()); // key2 (LSN 200)
        assert!(iter.next().is_none()); // key3 (LSN 300) not visible
    }

    #[test]
    fn test_scan_state() {
        let state = ScanState::forward(
            PageId::from(1),
            Some(b"key1".to_vec()),
            Some(b"key5".to_vec()),
            Lsn::from(100),
        );

        assert!(!state.started);
        assert!(!state.ended);
        assert_eq!(state.current_page, PageId::from(1));

        state.mark_started();
        assert!(state.started);
        assert!(state.is_active());

        state.mark_ended();
        assert!(!state.is_active());
    }

    #[test]
    fn test_scan_state_range_check() {
        let state = ScanState::forward(
            PageId::from(1),
            Some(b"key2".to_vec()),
            Some(b"key5".to_vec()),
            Lsn::from(100),
        );

        // Before start
        assert!(!state.is_in_range(b"key1"));

        // In range
        assert!(state.is_in_range(b"key2"));
        assert!(state.is_in_range(b"key3"));
        assert!(state.is_in_range(b"key4"));

        // At or after end
        assert!(!state.is_in_range(b"key5"));
        assert!(!state.is_in_range(b"key6"));
    }

    #[test]
    fn test_filter_by_snapshot() {
        let items = vec![
            ScanItem::new(b"key1".to_vec(), b"value1".to_vec(), Lsn::from(100)),
            ScanItem::new(b"key2".to_vec(), b"value2".to_vec(), Lsn::from(200)),
            ScanItem::new(b"key3".to_vec(), b"value3".to_vec(), Lsn::from(300)),
        ];

        let filtered = filter_by_snapshot(items, Lsn::from(250));
        assert_eq!(filtered.len(), 2);
        assert_eq!(filtered[0].key, b"key1");
        assert_eq!(filtered[1].key, b"key2");
    }

    #[test]
    fn test_merge_sorted_items() {
        let vec1 = vec![
            ScanItem::new(b"key1".to_vec(), b"value1".to_vec(), Lsn::from(100)),
            ScanItem::new(b"key3".to_vec(), b"value3".to_vec(), Lsn::from(300)),
        ];

        let vec2 = vec![
            ScanItem::new(b"key2".to_vec(), b"value2".to_vec(), Lsn::from(200)),
            ScanItem::new(b"key4".to_vec(), b"value4".to_vec(), Lsn::from(400)),
        ];

        let merged = merge_sorted_items(vec![vec1, vec2]);
        assert_eq!(merged.len(), 4);
        assert_eq!(merged[0].key, b"key1");
        assert_eq!(merged[1].key, b"key2");
        assert_eq!(merged[2].key, b"key3");
        assert_eq!(merged[3].key, b"key4");
    }
}
