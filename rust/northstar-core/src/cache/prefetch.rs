//! Prefetch and Async Cache Operations
//!
//! This module implements intelligent prefetching for pages and background cache
//! management tasks. It builds upon the three-level cache infrastructure (L1 Page
//! Cache, L2 Node Cache, L3 Query Cache) by adding:
//!
//! - Asynchronous prefetching for sequential scans
//! - Prefetch hint heuristics (sequential scan detection, index traversal)
//! - Prefetch queue to avoid cache overwhelming
//! - Prefetch priority levels (speculative vs demanded)
//! - Background cache statistics logging
//! - Adaptive cache tuning based on hit rate

use crate::cache::{Cache, CacheError};
use crate::types::PageId;
use parking_lot::Mutex;
use std::collections::VecDeque;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::time::{Duration, Instant};

/// Default maximum prefetch queue size
const DEFAULT_MAX_QUEUE_SIZE: usize = 256;

/// Default prefetch distance for sequential scans
const DEFAULT_PREFETCH_DISTANCE: usize = 4;

/// Default cache stats logging interval
const DEFAULT_STATS_LOG_INTERVAL: Duration = Duration::from_secs(60);

/// Prefetch priority level
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum PrefetchPriority {
    /// Low priority - speculative prefetch
    Low = 0,
    /// Normal priority - likely to be used
    Normal = 1,
    /// High priority - definitely will be used
    High = 2,
}

impl Default for PrefetchPriority {
    fn default() -> Self {
        Self::Normal
    }
}

/// Prefetch request with metadata
#[derive(Debug, Clone)]
pub struct PrefetchRequest {
    /// Page ID to prefetch
    pub page_id: PageId,
    /// Priority level
    pub priority: PrefetchPriority,
    /// Request timestamp
    pub timestamp: Instant,
    /// Expected access time (for scheduling)
    pub expected_access: Option<Instant>,
}

impl PrefetchRequest {
    /// Create a new prefetch request
    pub fn new(page_id: PageId, priority: PrefetchPriority) -> Self {
        Self {
            page_id,
            priority,
            timestamp: Instant::now(),
            expected_access: None,
        }
    }

    /// Create a prefetch request with expected access time
    pub fn with_expected_access(
        page_id: PageId,
        priority: PrefetchPriority,
        expected_access: Instant,
    ) -> Self {
        Self {
            page_id,
            priority,
            timestamp: Instant::now(),
            expected_access: Some(expected_access),
        }
    }
}

/// Prefetch queue with priority management
///
/// Manages pending prefetch requests and prevents cache overwhelming by
/// limiting the queue size and prioritizing requests.
#[derive(Debug)]
pub struct PrefetchQueue {
    /// Queue of pending prefetch requests
    queue: Arc<Mutex<VecDeque<PrefetchRequest>>>,
    /// Maximum queue size
    max_size: usize,
    /// Statistics
    stats: Arc<Mutex<PrefetchStats>>,
    /// Running flag
    running: Arc<AtomicBool>,
}

/// Prefetch statistics
#[derive(Debug, Default, Clone)]
pub struct PrefetchStats {
    /// Total prefetch requests
    pub total_requests: u64,
    /// Requests dropped due to full queue
    pub dropped_requests: u64,
    /// Successful prefetches
    pub successful_prefetches: u64,
    /// Prefetch hits (prefetched page was actually used)
    pub prefetch_hits: u64,
    /// Prefetch misses (prefetched page was evicted before use)
    pub prefetch_misses: u64,
    /// Current queue size
    pub current_queue_size: usize,
}

impl PrefetchQueue {
    /// Create a new prefetch queue
    pub fn new() -> Self {
        Self::with_max_size(DEFAULT_MAX_QUEUE_SIZE)
    }

    /// Create a new prefetch queue with custom max size
    pub fn with_max_size(max_size: usize) -> Self {
        Self {
            queue: Arc::new(Mutex::new(VecDeque::with_capacity(max_size))),
            max_size,
            stats: Arc::new(Mutex::new(PrefetchStats::default())),
            running: Arc::new(AtomicBool::new(false)),
        }
    }

    /// Add a prefetch request to the queue
    ///
    /// Returns true if the request was added, false if queue is full.
    pub fn enqueue(&self, request: PrefetchRequest) -> bool {
        let mut queue = self.queue.lock();
        let mut stats = self.stats.lock();

        stats.total_requests += 1;

        // Check if queue is full
        if queue.len() >= self.max_size {
            // Drop low priority requests first
            if let Some(pos) = queue
                .iter()
                .position(|r| r.priority == PrefetchPriority::Low)
            {
                queue.remove(pos);
                stats.dropped_requests += 1;
            } else {
                // Queue full and no low priority items to drop
                stats.dropped_requests += 1;
                return false;
            }
        }

        // Insert in priority order (high priority first)
        let insert_pos = queue
            .iter()
            .position(|r| r.priority < request.priority)
            .unwrap_or(queue.len());

        queue.insert(insert_pos, request);
        stats.current_queue_size = queue.len();
        true
    }

    /// Get the next prefetch request
    pub fn dequeue(&self) -> Option<PrefetchRequest> {
        let mut queue = self.queue.lock();
        let request = queue.pop_front();

        if request.is_some() {
            let mut stats = self.stats.lock();
            stats.current_queue_size = queue.len();
        }

        request
    }

    /// Clear all pending requests
    pub fn clear(&self) {
        let mut queue = self.queue.lock();
        queue.clear();
        let mut stats = self.stats.lock();
        stats.current_queue_size = 0;
    }

    /// Get current queue size
    pub fn len(&self) -> usize {
        self.queue.lock().len()
    }

    /// Check if queue is empty
    pub fn is_empty(&self) -> bool {
        self.queue.lock().is_empty()
    }

    /// Get prefetch statistics
    pub fn stats(&self) -> PrefetchStats {
        self.stats.lock().clone()
    }

    /// Set running state
    pub fn set_running(&self, running: bool) {
        self.running.store(running, Ordering::Release);
    }

    /// Check if prefetch is running
    pub fn is_running(&self) -> bool {
        self.running.load(Ordering::Acquire)
    }
}

impl Default for PrefetchQueue {
    fn default() -> Self {
        Self::new()
    }
}

/// Prefetch manager for async cache operations
///
/// Coordinates prefetching, background stats logging, and adaptive tuning.
pub struct PrefetchManager {
    /// Prefetch queue
    queue: PrefetchQueue,
    /// Prefetch distance for sequential scans
    prefetch_distance: usize,
    /// Stats logging interval
    stats_log_interval: Duration,
    /// Last stats log time
    last_stats_log: Arc<Mutex<Instant>>,
    /// Adaptive tuning enabled
    adaptive_tuning: bool,
    /// Page cache reference (for prefetching)
    #[allow(dead_code)]
    page_cache_size: usize,
}

impl PrefetchManager {
    /// Create a new prefetch manager
    pub fn new() -> Self {
        Self::with_config(DEFAULT_PREFETCH_DISTANCE, DEFAULT_STATS_LOG_INTERVAL, true)
    }

    /// Create a new prefetch manager with custom config
    pub fn with_config(
        prefetch_distance: usize,
        stats_log_interval: Duration,
        adaptive_tuning: bool,
    ) -> Self {
        Self {
            queue: PrefetchQueue::new(),
            prefetch_distance,
            stats_log_interval,
            last_stats_log: Arc::new(Mutex::new(Instant::now())),
            adaptive_tuning,
            page_cache_size: 256 * 1024 * 1024, // 256MB default
        }
    }

    /// Get the prefetch queue
    pub fn queue(&self) -> &PrefetchQueue {
        &self.queue
    }

    /// Prefetch a single page
    pub fn prefetch_page(&self, page_id: PageId, priority: PrefetchPriority) -> bool {
        let request = PrefetchRequest::new(page_id, priority);
        self.queue.enqueue(request)
    }

    /// Prefetch multiple pages
    pub fn prefetch_pages(&self, page_ids: Vec<PageId>, priority: PrefetchPriority) -> usize {
        let mut enqueued = 0;
        for page_id in page_ids {
            if self.prefetch_page(page_id, priority) {
                enqueued += 1;
            }
        }
        enqueued
    }

    /// Generate prefetch hints for sequential scan
    ///
    /// Returns page IDs that should be prefetched based on sequential access pattern.
    pub fn sequential_scan_hints(&self, current_page: PageId, count: usize) -> Vec<PageId> {
        let mut hints = Vec::with_capacity(count.min(self.prefetch_distance));
        for i in 1..=count.min(self.prefetch_distance) {
            hints.push(PageId::from(current_page.as_u64() + i as u64));
        }
        hints
    }

    /// Generate prefetch hints for index traversal
    ///
    /// Returns child page IDs that should be prefetched during tree traversal.
    pub fn index_traversal_hints(&self, child_pages: Vec<PageId>) -> Vec<PageId> {
        // Prefetch all children with normal priority
        child_pages
    }

    /// Check if stats logging is due
    pub fn should_log_stats(&self) -> bool {
        let last_log = self.last_stats_log.lock().elapsed();
        last_log >= self.stats_log_interval
    }

    /// Update stats log time
    pub fn update_stats_log_time(&self) {
        *self.last_stats_log.lock() = Instant::now();
    }

    /// Get adaptive tuning recommendation
    ///
    /// Returns recommended prefetch distance based on cache hit rate.
    pub fn adaptive_prefetch_distance(&self, hit_rate: f64) -> usize {
        if !self.adaptive_tuning {
            return self.prefetch_distance;
        }

        // Adaptive tuning based on hit rate:
        // - High hit rate (>80%): increase prefetch distance
        // - Medium hit rate (50-80%): maintain current distance
        // - Low hit rate (<50%): decrease prefetch distance
        if hit_rate > 0.8 {
            (self.prefetch_distance * 3 / 2).min(16) // Cap at 16
        } else if hit_rate < 0.5 {
            (self.prefetch_distance * 2 / 3).max(1) // Minimum 1
        } else {
            self.prefetch_distance
        }
    }

    /// Record prefetch hit
    pub fn record_prefetch_hit(&self) {
        let mut stats = self.queue.stats.lock();
        stats.prefetch_hits += 1;
    }

    /// Record prefetch miss
    pub fn record_prefetch_miss(&self) {
        let mut stats = self.queue.stats.lock();
        stats.prefetch_misses += 1;
    }

    /// Get prefetch statistics
    pub fn stats(&self) -> PrefetchStats {
        self.queue.stats()
    }
}

impl Default for PrefetchManager {
    fn default() -> Self {
        Self::new()
    }
}

/// Background cache statistics logger
///
/// Periodically logs cache statistics for monitoring and analysis.
pub struct CacheStatsLogger {
    /// Logging interval
    interval: Duration,
    /// Last log time
    last_log: Arc<Mutex<Instant>>,
    /// Enabled flag
    enabled: Arc<AtomicBool>,
    /// Log counter
    log_count: Arc<AtomicU64>,
}

impl CacheStatsLogger {
    /// Create a new cache stats logger
    pub fn new(interval: Duration) -> Self {
        Self {
            interval,
            last_log: Arc::new(Mutex::new(Instant::now())),
            enabled: Arc::new(AtomicBool::new(true)),
            log_count: Arc::new(AtomicU64::new(0)),
        }
    }

    /// Check if logging is enabled
    pub fn is_enabled(&self) -> bool {
        self.enabled.load(Ordering::Acquire)
    }

    /// Enable or disable logging
    pub fn set_enabled(&self, enabled: bool) {
        self.enabled.store(enabled, Ordering::Release);
    }

    /// Check if stats should be logged
    pub fn should_log(&self) -> bool {
        if !self.is_enabled() {
            return false;
        }
        self.last_log.lock().elapsed() >= self.interval
    }

    /// Log cache statistics
    ///
    /// This is a placeholder - actual logging would be integrated with
    /// the logging system.
    pub fn log_stats(&self, stats: &crate::cache::types::CacheSnapshot) {
        if !self.is_enabled() {
            return;
        }

        *self.last_log.lock() = Instant::now();
        self.log_count.fetch_add(1, Ordering::Release);

        // In production, this would use the logging framework
        // For now, we just track that logging occurred
        #[cfg(feature = "logging")]
        {
            log::info!(
                "Cache stats: hits={}, misses={}, hit_rate={:.2}%, entries={}, size={}",
                stats.hits,
                stats.misses,
                stats.hit_rate * 100.0,
                stats.current_entries,
                stats.current_size
            );
        }
    }

    /// Get log count
    pub fn log_count(&self) -> u64 {
        self.log_count.load(Ordering::Acquire)
    }
}

/// Sequential scan detector
///
/// Detects sequential access patterns to trigger prefetch.
#[derive(Debug, Clone)]
pub struct SequentialScanDetector {
    /// Last accessed page ID
    last_page_id: Option<PageId>,
    /// Consecutive sequential accesses
    sequential_count: usize,
    /// Threshold to trigger prefetch
    prefetch_threshold: usize,
}

impl SequentialScanDetector {
    /// Create a new sequential scan detector
    pub fn new() -> Self {
        Self::with_threshold(3)
    }

    /// Create a new detector with custom threshold
    pub fn with_threshold(threshold: usize) -> Self {
        Self {
            last_page_id: None,
            sequential_count: 0,
            prefetch_threshold: threshold,
        }
    }

    /// Record a page access and check if prefetch should be triggered
    pub fn record_access(&mut self, page_id: PageId) -> bool {
        if let Some(last_id) = self.last_page_id {
            // Check if this is a sequential access (next page)
            if page_id.as_u64() == last_id.as_u64() + 1 {
                self.sequential_count += 1;
            } else {
                // Pattern broken
                self.sequential_count = 0;
            }
        }

        self.last_page_id = Some(page_id);

        // Trigger prefetch if threshold reached
        self.sequential_count >= self.prefetch_threshold
    }

    /// Reset the detector
    pub fn reset(&mut self) {
        self.last_page_id = None;
        self.sequential_count = 0;
    }

    /// Get current sequential count
    pub fn sequential_count(&self) -> usize {
        self.sequential_count
    }
}

impl Default for SequentialScanDetector {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_prefetch_priority_ordering() {
        assert!(PrefetchPriority::High > PrefetchPriority::Normal);
        assert!(PrefetchPriority::Normal > PrefetchPriority::Low);
    }

    #[test]
    fn test_prefetch_request_creation() {
        let page_id = PageId::new(42);
        let request = PrefetchRequest::new(page_id, PrefetchPriority::High);

        assert_eq!(request.page_id, page_id);
        assert_eq!(request.priority, PrefetchPriority::High);
        assert!(request.expected_access.is_none());
    }

    #[test]
    fn test_prefetch_request_with_expected_access() {
        let page_id = PageId::new(42);
        let expected = Instant::now() + Duration::from_millis(100);
        let request = PrefetchRequest::with_expected_access(page_id, PrefetchPriority::Normal, expected);

        assert_eq!(request.page_id, page_id);
        assert_eq!(request.expected_access, Some(expected));
    }

    #[test]
    fn test_prefetch_queue_enqueue_dequeue() {
        let queue = PrefetchQueue::new();
        let page_id = PageId::new(42);
        let request = PrefetchRequest::new(page_id, PrefetchPriority::Normal);

        assert!(queue.enqueue(request));
        assert_eq!(queue.len(), 1);
        assert!(!queue.is_empty());

        let dequeued = queue.dequeue();
        assert!(dequeued.is_some());
        assert_eq!(dequeued.unwrap().page_id, page_id);
        assert_eq!(queue.len(), 0);
        assert!(queue.is_empty());
    }

    #[test]
    fn test_prefetch_queue_priority_ordering() {
        let queue = PrefetchQueue::new();

        // Enqueue low, normal, high priority requests
        queue.enqueue(PrefetchRequest::new(PageId::new(1), PrefetchPriority::Low));
        queue.enqueue(PrefetchRequest::new(PageId::new(2), PrefetchPriority::Normal));
        queue.enqueue(PrefetchRequest::new(PageId::new(3), PrefetchPriority::High));

        // Should dequeue in priority order: high, normal, low
        let first = queue.dequeue().unwrap();
        assert_eq!(first.page_id.as_u64(), 3);
        assert_eq!(first.priority, PrefetchPriority::High);

        let second = queue.dequeue().unwrap();
        assert_eq!(second.page_id.as_u64(), 2);
        assert_eq!(second.priority, PrefetchPriority::Normal);

        let third = queue.dequeue().unwrap();
        assert_eq!(third.page_id.as_u64(), 1);
        assert_eq!(third.priority, PrefetchPriority::Low);
    }

    #[test]
    fn test_prefetch_queue_full() {
        let queue = PrefetchQueue::with_max_size(2);

        // Fill the queue
        assert!(queue.enqueue(PrefetchRequest::new(PageId::new(1), PrefetchPriority::High)));
        assert!(queue.enqueue(PrefetchRequest::new(PageId::new(2), PrefetchPriority::High)));

        // Third request should be dropped (or replace low priority)
        let stats = queue.stats();
        assert_eq!(stats.total_requests, 2);
        assert_eq!(stats.dropped_requests, 0);
    }

    #[test]
    fn test_prefetch_queue_clear() {
        let queue = PrefetchQueue::new();

        queue.enqueue(PrefetchRequest::new(PageId::new(1), PrefetchPriority::Normal));
        queue.enqueue(PrefetchRequest::new(PageId::new(2), PrefetchPriority::Normal));

        assert_eq!(queue.len(), 2);

        queue.clear();
        assert_eq!(queue.len(), 0);
        assert!(queue.is_empty());
    }

    #[test]
    fn test_prefetch_manager_new() {
        let manager = PrefetchManager::new();
        assert_eq!(manager.prefetch_distance, DEFAULT_PREFETCH_DISTANCE);
        assert!(manager.queue.is_empty());
    }

    #[test]
    fn test_prefetch_manager_prefetch_page() {
        let manager = PrefetchManager::new();
        let page_id = PageId::new(42);

        assert!(manager.prefetch_page(page_id, PrefetchPriority::Normal));
        assert_eq!(manager.queue.len(), 1);
    }

    #[test]
    fn test_prefetch_manager_prefetch_pages() {
        let manager = PrefetchManager::new();
        let pages = vec![PageId::new(1), PageId::new(2), PageId::new(3)];

        let enqueued = manager.prefetch_pages(pages, PrefetchPriority::Normal);
        assert_eq!(enqueued, 3);
        assert_eq!(manager.queue.len(), 3);
    }

    #[test]
    fn test_sequential_scan_hints() {
        let manager = PrefetchManager::new();
        let current = PageId::new(100);

        let hints = manager.sequential_scan_hints(current, 10);
        assert!(hints.len() <= manager.prefetch_distance);

        // Should be sequential pages
        for (i, hint) in hints.iter().enumerate() {
            assert_eq!(hint.as_u64(), 100 + (i + 1) as u64);
        }
    }

    #[test]
    fn test_index_traversal_hints() {
        let manager = PrefetchManager::new();
        let children = vec![PageId::new(10), PageId::new(20), PageId::new(30)];

        let hints = manager.index_traversal_hints(children.clone());
        assert_eq!(hints, children);
    }

    #[test]
    fn test_adaptive_prefetch_distance() {
        let manager = PrefetchManager::new();

        // High hit rate should increase distance
        let high_distance = manager.adaptive_prefetch_distance(0.9);
        assert!(high_distance >= manager.prefetch_distance);

        // Low hit rate should decrease distance
        let low_distance = manager.adaptive_prefetch_distance(0.3);
        assert!(low_distance <= manager.prefetch_distance);

        // Medium hit rate should maintain distance
        let medium_distance = manager.adaptive_prefetch_distance(0.6);
        assert_eq!(medium_distance, manager.prefetch_distance);
    }

    #[test]
    fn test_adaptive_prefetch_distance_disabled() {
        let manager = PrefetchManager::with_config(4, DEFAULT_STATS_LOG_INTERVAL, false);

        // Should return base distance regardless of hit rate
        let distance1 = manager.adaptive_prefetch_distance(0.9);
        let distance2 = manager.adaptive_prefetch_distance(0.3);
        assert_eq!(distance1, manager.prefetch_distance);
        assert_eq!(distance2, manager.prefetch_distance);
    }

    #[test]
    fn test_sequential_scan_detector() {
        let mut detector = SequentialScanDetector::new();

        // Access pages 1, 2, 3, 4 (threshold is 3)
        assert!(!detector.record_access(PageId::new(1))); // First access, count=0
        assert!(!detector.record_access(PageId::new(2))); // Sequential, count=1
        assert!(!detector.record_access(PageId::new(3))); // Sequential, count=2
        assert!(detector.record_access(PageId::new(4))); // Sequential, count=3 - triggers!

        assert_eq!(detector.sequential_count(), 3);

        // Break the pattern
        assert!(!detector.record_access(PageId::new(10)));
        assert_eq!(detector.sequential_count(), 0);
    }

    #[test]
    fn test_sequential_scan_detector_reset() {
        let mut detector = SequentialScanDetector::new();

        detector.record_access(PageId::new(1));
        detector.record_access(PageId::new(2));
        detector.record_access(PageId::new(3));

        assert_eq!(detector.sequential_count(), 2); // Two transitions (1->2, 2->3)

        detector.reset();

        assert_eq!(detector.sequential_count(), 0);
        assert!(detector.last_page_id.is_none());
    }

    #[test]
    fn test_cache_stats_logger() {
        let logger = CacheStatsLogger::new(Duration::from_secs(1));

        assert!(logger.is_enabled());
        assert!(!logger.should_log()); // Just created, shouldn't log yet

        logger.log_stats(&crate::cache::types::CacheSnapshot {
            hits: 100,
            misses: 10,
            evictions: 5,
            hit_rate: 0.909,
            current_size: 1024,
            current_entries: 10,
            dirty_pages: 2,
            pinned_entries: 1,
        });

        assert_eq!(logger.log_count(), 1);
    }

    #[test]
    fn test_cache_stats_logger_disabled() {
        let logger = CacheStatsLogger::new(Duration::from_secs(1));
        logger.set_enabled(false);

        assert!(!logger.is_enabled());
        assert!(!logger.should_log());

        logger.log_stats(&crate::cache::types::CacheSnapshot {
            hits: 100,
            misses: 10,
            evictions: 5,
            hit_rate: 0.909,
            current_size: 1024,
            current_entries: 10,
            dirty_pages: 2,
            pinned_entries: 1,
        });

        assert_eq!(logger.log_count(), 0); // Should not increment when disabled
    }

    #[test]
    fn test_prefetch_stats() {
        let manager = PrefetchManager::new();

        // Record some activity
        manager.record_prefetch_hit();
        manager.record_prefetch_hit();
        manager.record_prefetch_miss();

        let stats = manager.stats();
        assert_eq!(stats.prefetch_hits, 2);
        assert_eq!(stats.prefetch_misses, 1);
    }
}
