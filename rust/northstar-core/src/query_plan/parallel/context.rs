//! Parallel Execution Context
//!
//! This module provides thread-local execution context for parallel query execution,
//! allowing each worker thread to maintain its own state during parallel operations.

use std::collections::HashMap;
use std::sync::Arc;

/// Thread-local execution context for parallel query operations.
///
/// Each worker thread gets its own context instance, which maintains:
/// - Thread identifier for debugging and metrics
/// - Batch size for processing data
/// - Thread-local state for operations like hash tables
#[derive(Debug, Clone)]
pub struct ParallelContext {
    /// Unique identifier for this thread/worker
    pub thread_id: usize,
    /// Number of rows to process per batch
    pub batch_size: usize,
    /// Thread-local state storage
    pub local_state: HashMap<String, Vec<u8>>,
}

impl ParallelContext {
    /// Creates a new parallel context for the given thread.
    pub fn new(thread_id: usize, batch_size: usize) -> Self {
        Self {
            thread_id,
            batch_size,
            local_state: HashMap::new(),
        }
    }

    /// Creates a context with default batch size.
    pub fn with_defaults(thread_id: usize) -> Self {
        Self::new(thread_id, 1000)
    }

    /// Returns the thread ID.
    pub fn thread_id(&self) -> usize {
        self.thread_id
    }

    /// Returns the batch size.
    pub fn batch_size(&self) -> usize {
        self.batch_size
    }

    /// Sets the batch size.
    pub fn with_batch_size(mut self, batch_size: usize) -> Self {
        self.batch_size = batch_size;
        self
    }

    /// Stores thread-local data under a key.
    pub fn set_local(&mut self, key: impl Into<String>, data: Vec<u8>) {
        self.local_state.insert(key.into(), data);
    }

    /// Retrieves thread-local data by key.
    pub fn get_local(&self, key: &str) -> Option<&[u8]> {
        self.local_state.get(key).map(|v| v.as_slice())
    }

    /// Removes and returns thread-local data by key.
    pub fn take_local(&mut self, key: &str) -> Option<Vec<u8>> {
        self.local_state.remove(key)
    }

    /// Clears all thread-local state.
    pub fn clear_state(&mut self) {
        self.local_state.clear();
    }

    /// Returns true if there is local state stored under the given key.
    pub fn has_local(&self, key: &str) -> bool {
        self.local_state.contains_key(key)
    }
}

/// Thread-local state for specific operations.
///
/// This provides type-safe storage for operation-specific state
/// like hash tables for joins or partial aggregates.
#[derive(Debug)]
pub enum ThreadLocalState {
    /// Hash table for parallel hash join
    JoinHashTable(JoinHashTable),
    /// Partial aggregates for parallel aggregation
    PartialAggregates(PartialAggregates),
    /// Buffer for collecting results
    ResultBuffer(ResultBuffer),
}

/// Thread-local hash table for hash join operations.
#[derive(Debug)]
pub struct JoinHashTable {
    /// Partition ID this hash table belongs to
    pub partition_id: usize,
    /// Number of entries in the hash table
    pub entry_count: usize,
    /// Estimated memory usage in bytes
    pub memory_usage: usize,
}

impl JoinHashTable {
    /// Creates a new empty hash table.
    pub fn new(partition_id: usize) -> Self {
        Self {
            partition_id,
            entry_count: 0,
            memory_usage: 0,
        }
    }

    /// Returns the partition ID.
    pub fn partition_id(&self) -> usize {
        self.partition_id
    }

    /// Returns the number of entries.
    pub fn entry_count(&self) -> usize {
        self.entry_count
    }

    /// Returns the estimated memory usage.
    pub fn memory_usage(&self) -> usize {
        self.memory_usage
    }

    /// Updates the entry count and memory usage.
    pub fn update_stats(&mut self, entry_count: usize, memory_usage: usize) {
        self.entry_count = entry_count;
        self.memory_usage = memory_usage;
    }
}

/// Thread-local partial aggregates for aggregation operations.
#[derive(Debug)]
pub struct PartialAggregates {
    /// Partition ID these aggregates belong to
    pub partition_id: usize,
    /// Number of groups in this partition
    pub group_count: usize,
    /// Number of rows processed
    pub rows_processed: usize,
    /// Estimated memory usage in bytes
    pub memory_usage: usize,
}

impl PartialAggregates {
    /// Creates a new empty partial aggregates container.
    pub fn new(partition_id: usize) -> Self {
        Self {
            partition_id,
            group_count: 0,
            rows_processed: 0,
            memory_usage: 0,
        }
    }

    /// Returns the partition ID.
    pub fn partition_id(&self) -> usize {
        self.partition_id
    }

    /// Returns the number of groups.
    pub fn group_count(&self) -> usize {
        self.group_count
    }

    /// Returns the number of rows processed.
    pub fn rows_processed(&self) -> usize {
        self.rows_processed
    }

    /// Returns the estimated memory usage.
    pub fn memory_usage(&self) -> usize {
        self.memory_usage
    }

    /// Updates the aggregate statistics.
    pub fn update_stats(&mut self, group_count: usize, rows_processed: usize, memory_usage: usize) {
        self.group_count = group_count;
        self.rows_processed = rows_processed;
        self.memory_usage = memory_usage;
    }
}

/// Thread-local result buffer for collecting query results.
#[derive(Debug)]
pub struct ResultBuffer {
    /// Thread ID that owns this buffer
    pub thread_id: usize,
    /// Number of rows in the buffer
    pub row_count: usize,
    /// Buffer capacity in bytes
    pub capacity: usize,
    /// Current buffer size in bytes
    pub size: usize,
}

impl ResultBuffer {
    /// Creates a new empty result buffer.
    pub fn new(thread_id: usize, capacity: usize) -> Self {
        Self {
            thread_id,
            row_count: 0,
            capacity,
            size: 0,
        }
    }

    /// Returns the thread ID.
    pub fn thread_id(&self) -> usize {
        self.thread_id
    }

    /// Returns the number of rows in the buffer.
    pub fn row_count(&self) -> usize {
        self.row_count
    }

    /// Returns the buffer capacity.
    pub fn capacity(&self) -> usize {
        self.capacity
    }

    /// Returns the current buffer size.
    pub fn size(&self) -> usize {
        self.size
    }

    /// Returns the remaining capacity.
    pub fn remaining(&self) -> usize {
        self.capacity.saturating_sub(self.size)
    }

    /// Returns true if the buffer is full.
    pub fn is_full(&self) -> bool {
        self.size >= self.capacity
    }

    /// Updates the buffer statistics.
    pub fn update_stats(&mut self, row_count: usize, size: usize) {
        self.row_count = row_count;
        self.size = size;
    }

    /// Clears the buffer.
    pub fn clear(&mut self) {
        self.row_count = 0;
        self.size = 0;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_parallel_context() {
        let ctx = ParallelContext::new(0, 100);

        assert_eq!(ctx.thread_id(), 0);
        assert_eq!(ctx.batch_size(), 100);

        let ctx = ctx.with_batch_size(200);
        assert_eq!(ctx.batch_size(), 200);
    }

    #[test]
    fn test_local_state() {
        let mut ctx = ParallelContext::with_defaults(0);

        assert!(!ctx.has_local("test_key"));
        assert!(ctx.get_local("test_key").is_none());

        ctx.set_local("test_key", vec![1, 2, 3]);
        assert!(ctx.has_local("test_key"));
        assert_eq!(ctx.get_local("test_key"), Some(&[1, 2, 3][..]));

        let data = ctx.take_local("test_key");
        assert_eq!(data, Some(vec![1, 2, 3]));
        assert!(!ctx.has_local("test_key"));
    }

    #[test]
    fn test_join_hash_table() {
        let mut table = JoinHashTable::new(0);

        assert_eq!(table.partition_id(), 0);
        assert_eq!(table.entry_count(), 0);
        assert_eq!(table.memory_usage(), 0);

        table.update_stats(100, 1024);
        assert_eq!(table.entry_count(), 100);
        assert_eq!(table.memory_usage(), 1024);
    }

    #[test]
    fn test_partial_aggregates() {
        let mut aggregates = PartialAggregates::new(0);

        assert_eq!(aggregates.partition_id(), 0);
        assert_eq!(aggregates.group_count(), 0);
        assert_eq!(aggregates.rows_processed(), 0);

        aggregates.update_stats(10, 1000, 2048);
        assert_eq!(aggregates.group_count(), 10);
        assert_eq!(aggregates.rows_processed(), 1000);
        assert_eq!(aggregates.memory_usage(), 2048);
    }

    #[test]
    fn test_result_buffer() {
        let mut buffer = ResultBuffer::new(0, 4096);

        assert_eq!(buffer.thread_id(), 0);
        assert_eq!(buffer.capacity(), 4096);
        assert_eq!(buffer.size(), 0);
        assert_eq!(buffer.remaining(), 4096);
        assert!(!buffer.is_full());

        buffer.update_stats(100, 2048);
        assert_eq!(buffer.row_count(), 100);
        assert_eq!(buffer.size(), 2048);
        assert_eq!(buffer.remaining(), 2048);

        buffer.update_stats(200, 4096);
        assert!(buffer.is_full());

        buffer.clear();
        assert_eq!(buffer.row_count(), 0);
        assert_eq!(buffer.size(), 0);
        assert!(!buffer.is_full());
    }
}
