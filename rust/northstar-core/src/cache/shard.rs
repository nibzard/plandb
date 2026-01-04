//! Cache shard implementation with eviction policies

use std::collections::{BinaryHeap, HashMap, LinkedList, VecDeque};
use std::hash::Hash;
use std::sync::atomic::Ordering;

use parking_lot::{Mutex, RwLock};

use crate::cache::error::{CacheError, CacheResult};
use crate::cache::types::{
    AccessCountEntry, ArcState, CacheConfig, CacheEntry, CachePolicy, CacheStats,
};

/// Single cache shard with independent lock for concurrent access
pub struct CacheShard<K, V>
where
    K: Clone + Eq + Hash,
{
    /// Protected entry map
    pub entries: RwLock<HashMap<K, CacheEntry<V>>>,
    /// Eviction policy for this shard
    pub policy: CachePolicy,
    /// LRU tracking (LRU policy only) - use VecDeque for stable API
    pub lru_list: Mutex<VecDeque<K>>,
    /// LFU tracking (LFU policy only)
    pub lfu_heap: Mutex<BinaryHeap<AccessCountEntry<K>>>,
    /// ARC adaptive state (ARC policy only)
    pub arc_state: Mutex<ArcState<K>>,
    /// Configuration
    pub config: CacheConfig,
    /// Statistics
    pub stats: CacheStats,
    /// Shard index for debugging
    pub shard_index: usize,
}

impl<K, V> CacheShard<K, V>
where
    K: Clone + Eq + Hash,
{
    /// Create a new cache shard
    pub fn new(policy: CachePolicy, config: CacheConfig, shard_index: usize) -> Self {
        Self {
            entries: RwLock::new(HashMap::new()),
            policy,
            lru_list: Mutex::new(VecDeque::new()),
            lfu_heap: Mutex::new(BinaryHeap::new()),
            arc_state: Mutex::new(ArcState::new()),
            config,
            stats: CacheStats::new(),
            shard_index,
        }
    }

    /// Get entry without locking (internal use only)
    pub(crate) fn get_entry_unchecked(&self, key: &K) -> Option<&CacheEntry<V>> {
        // SAFETY: Caller must hold read lock
        unsafe {
            let entries = &self.entries as *const RwLock<_> as *const HashMap<K, CacheEntry<V>>;
            (*entries).get(key)
        }
    }

    /// Get value from cache
    pub fn get(&self, key: &K) -> Option<V>
    where
        V: Clone,
    {
        let entries = self.entries.read();
        let entry = entries.get(key)?;

        // Record access
        self.stats.record_hit();
        entry.pin();

        // Clone value while holding read lock
        let value = entry.value.clone();
        entry.unpin();
        drop(entries);

        // Update metadata (need write for mutation)
        let mut entries = self.entries.write();
        if let Some(entry) = entries.get_mut(key) {
            entry.record_access();
            self.update_policy_tracking(key);
        }

        Some(value)
    }

    /// Insert or update entry in cache
    pub fn put(&self, key: K, value: V, size: usize) -> CacheResult<()>
    where
        V: Clone,
    {
        // Validate size
        if size > self.config.max_size {
            return Err(CacheError::EntryTooLarge {
                size,
                max_size: self.config.max_size,
            });
        }

        {
            let mut entries = self.entries.write();

            // Check if key already exists
            if let Some(entry) = entries.get_mut(&key) {
                // Update existing entry
                entry.value = value;
                entry.record_access();
                drop(entries);
                return Ok(());
            }
        }

        // Check capacity constraints
        let current_size = self.stats.size();
        let current_entries = self.stats.entry_count();
        let new_size = current_size + size;
        let new_entries = current_entries + 1;

        if new_size > self.config.max_size || new_entries > self.config.max_entries {
            // Trigger eviction
            let required_bytes = new_size.saturating_sub(self.config.max_size);
            let required_entries = new_entries.saturating_sub(self.config.max_entries);
            self.evict(required_bytes, required_entries)?;
        }

        // Insert new entry
        {
            let mut entries = self.entries.write();
            let entry = CacheEntry::new(value, size);
            entries.insert(key.clone(), entry);
            self.stats.record_insertion();
            self.stats.current_size.fetch_add(size, Ordering::Relaxed);
            self.stats.current_entries.fetch_add(1, Ordering::Relaxed);
        }

        self.update_policy_tracking(&key);

        Ok(())
    }

    /// Invalidate (remove) entry from cache
    pub fn invalidate(&self, key: &K) -> bool
    where
        V: Clone,
    {
        let mut entries = self.entries.write();
        if let Some(entry) = entries.remove(key) {
            self.stats.current_size.fetch_sub(entry.size, Ordering::Relaxed);
            self.stats.current_entries.fetch_sub(1, Ordering::Relaxed);
            self.stats.record_eviction();

            if entry.dirty {
                self.stats.record_dirty_eviction();
            }

            // Remove from policy tracking
            self.remove_policy_tracking(key);

            true
        } else {
            false
        }
    }

    /// Pin entry to prevent eviction
    pub fn pin(&self, key: &K) -> bool {
        let entries = self.entries.read();
        if let Some(entry) = entries.get(key) {
            entry.pin();
            self.stats.pin_count.fetch_add(1, Ordering::Relaxed);
            true
        } else {
            false
        }
    }

    /// Unpin entry
    pub fn unpin(&self, key: &K) -> bool {
        let entries = self.entries.read();
        if let Some(entry) = entries.get(key) {
            let new_count = entry.unpin();
            if new_count == 0 {
                self.stats.pin_count.fetch_sub(1, Ordering::Relaxed);
            }
            true
        } else {
            false
        }
    }

    /// Clear all entries
    pub fn clear(&self) -> crate::cache::types::ClearResult {
        let mut result = crate::cache::types::ClearResult::default();

        let mut entries = self.entries.write();
        result.entries_cleared = entries.len();
        result.memory_freed = self.stats.size();

        // Count dirty pages
        for entry in entries.values() {
            if entry.dirty {
                result.dirty_pages_written += 1;
            }
        }

        entries.clear();
        self.stats.current_size.store(0, Ordering::Relaxed);
        self.stats.current_entries.store(0, Ordering::Relaxed);

        // Clear policy tracking
        match self.policy {
            CachePolicy::Lru => {
                self.lru_list.lock().clear();
            }
            CachePolicy::Lfu => {
                self.lfu_heap.lock().clear();
            }
            CachePolicy::Arc => {
                let mut state = self.arc_state.lock();
                state.t1.clear();
                state.t2.clear();
            }
            _ => {}
        }

        result
    }

    /// Get current statistics
    pub fn stats(&self) -> crate::cache::types::CacheSnapshot {
        crate::cache::types::CacheSnapshot {
            hits: self.stats.hits.load(Ordering::Relaxed),
            misses: self.stats.misses.load(Ordering::Relaxed),
            evictions: self.stats.evictions.load(Ordering::Relaxed),
            hit_rate: self.stats.hit_rate(),
            current_size: self.stats.size(),
            current_entries: self.stats.entry_count(),
            dirty_pages: self.dirty_count(),
            pinned_entries: self.stats.pinned_count(),
        }
    }

    /// Evict entries based on policy
    fn evict(&self, required_bytes: usize, required_entries: usize) -> CacheResult<()> {
        let mut freed_bytes = 0;
        let mut freed_entries = 0;
        let max_attempts = self.config.max_entries;

        for _ in 0..max_attempts {
            if freed_bytes >= required_bytes && freed_entries >= required_entries {
                break;
            }

            let victim = match self.policy {
                CachePolicy::Lru => self.evict_lru(),
                CachePolicy::Lfu => self.evict_lfu(),
                CachePolicy::Arc => self.evict_arc(),
                CachePolicy::Fifo => self.evict_fifo(),
                CachePolicy::Lifo => self.evict_lifo(),
            };

            match victim {
                Some((key, size, dirty)) => {
                    let mut entries = self.entries.write();
                    if entries.remove(&key).is_some() {
                        freed_bytes += size;
                        freed_entries += 1;
                        self.stats.current_size.fetch_sub(size, Ordering::Relaxed);
                        self.stats.current_entries.fetch_sub(1, Ordering::Relaxed);
                        self.stats.record_eviction();
                        if dirty {
                            self.stats.record_dirty_eviction();
                        }
                    }
                }
                None => {
                    // No more evictable entries
                    if freed_bytes < required_bytes || freed_entries < required_entries {
                        return Err(CacheError::CacheFull);
                    }
                    break;
                }
            }
        }

        Ok(())
    }

    /// Evict LRU entry (oldest in list)
    fn evict_lru(&self) -> Option<(K, usize, bool)> {
        let mut list = self.lru_list.lock();
        // Pop from back (oldest)
        while let Some(key) = list.pop_back() {
            let entries = self.entries.read();
            if let Some(entry) = entries.get(&key) {
                if entry.is_pinned() {
                    // Skip pinned entries
                    continue;
                }
                return Some((key, entry.size, entry.dirty));
            }
        }
        None
    }

    /// Evict LFU entry (lowest access count)
    fn evict_lfu(&self) -> Option<(K, usize, bool)> {
        let mut heap = self.lfu_heap.lock();
        while let Some(access_entry) = heap.pop() {
            let entries = self.entries.read();
            if let Some(entry) = entries.get(&access_entry.key) {
                if entry.is_pinned() {
                    continue;
                }
                return Some((access_entry.key.clone(), entry.size, entry.dirty));
            }
        }
        None
    }

    /// Evict ARC entry
    fn evict_arc(&self) -> Option<(K, usize, bool)> {
        let mut state = self.arc_state.lock();
        let t1_keys: Vec<_> = state.t1.keys().cloned().collect();
        let t2_keys: Vec<_> = state.t2.keys().cloned().collect();

        let keys_to_try = if state.delta_t1 > state.delta_t2 {
            // Prefer evicting from T2 (frequent)
            t2_keys
        } else {
            // Prefer evicting from T1 (recent)
            t1_keys
        };

        for key in keys_to_try {
            let entries = self.entries.read();
            if let Some(entry) = entries.get(&key) {
                if entry.is_pinned() {
                    continue;
                }
                state.remove(&key);
                return Some((key, entry.size, entry.dirty));
            }
        }

        None
    }

    /// Evict FIFO entry (first in)
    fn evict_fifo(&self) -> Option<(K, usize, bool)> {
        let entries = self.entries.read();
        // Find first entry (by iteration order)
        for (key, entry) in entries.iter() {
            if !entry.is_pinned() {
                return Some((key.clone(), entry.size, entry.dirty));
            }
        }
        None
    }

    /// Evict LIFO entry (last in)
    fn evict_lifo(&self) -> Option<(K, usize, bool)> {
        let entries = self.entries.read();
        // Collect and find last non-pinned entry
        let mut last_key: Option<&K> = None;
        let mut last_entry: Option<&CacheEntry<V>> = None;

        for (key, entry) in entries.iter() {
            if !entry.is_pinned() {
                last_key = Some(key);
                last_entry = Some(entry);
            }
        }

        match (last_key, last_entry) {
            (Some(key), Some(entry)) => Some((key.clone(), entry.size, entry.dirty)),
            _ => None,
        }
    }

    /// Update policy-specific tracking on access
    fn update_policy_tracking(&self, key: &K) {
        match self.policy {
            CachePolicy::Lru => {
                let mut list = self.lru_list.lock();
                // Remove key if present
                list.retain(|k| k != key);
                // Add to front (newest)
                list.push_front(key.clone());
            }
            CachePolicy::Lfu => {
                let entries = self.entries.read();
                if let Some(entry) = entries.get(key) {
                    let mut heap = self.lfu_heap.lock();
                    heap.push(AccessCountEntry {
                        key: key.clone(),
                        access_count: entry.access_count,
                    });
                }
            }
            CachePolicy::Arc => {
                let mut state = self.arc_state.lock();
                // Update ARC adaptive state
                if state.in_t1(key) {
                    state.delta_t1 += 1;
                } else if state.in_t2(key) {
                    state.delta_t2 += 1;
                }
            }
            _ => {}
        }
    }

    /// Remove from policy tracking
    fn remove_policy_tracking(&self, key: &K) {
        match self.policy {
            CachePolicy::Lru => {
                let mut list = self.lru_list.lock();
                list.retain(|k| k != key);
            }
            CachePolicy::Arc => {
                let mut state = self.arc_state.lock();
                state.remove(key);
            }
            _ => {}
        }
    }

    /// Count dirty entries
    pub fn dirty_count(&self) -> usize {
        let entries = self.entries.read();
        entries.values().filter(|e| e.dirty).count()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_shard_basic_operations() {
        let config = CacheConfig::default();
        let shard = CacheShard::new(CachePolicy::Lru, config, 0);

        // Put and get
        shard.put("key1".to_string(), 42, 8).unwrap();
        assert_eq!(shard.get(&"key1".to_string()), Some(42));
        assert_eq!(shard.stats.entry_count(), 1);

        // Update
        shard.put("key1".to_string(), 100, 8).unwrap();
        assert_eq!(shard.get(&"key1".to_string()), Some(100));
        assert_eq!(shard.stats.entry_count(), 1);

        // Invalidate
        assert!(shard.invalidate(&"key1".to_string()));
        assert_eq!(shard.get(&"key1".to_string()), None);
    }

    #[test]
    fn test_shard_eviction() {
        let mut config = CacheConfig::default();
        config.max_size = 32; // Small size to trigger eviction
        config.max_entries = 2;

        let shard = CacheShard::new(CachePolicy::Lru, config, 0);

        // Insert entries until eviction triggers
        shard.put("key1".to_string(), 1, 8).unwrap();
        shard.put("key2".to_string(), 2, 8).unwrap();
        shard.put("key3".to_string(), 3, 8).unwrap(); // Should evict key1

        assert_eq!(shard.get(&"key1".to_string()), None);
        assert_eq!(shard.get(&"key2".to_string()), Some(2));
        assert_eq!(shard.get(&"key3".to_string()), Some(3));
    }

    #[test]
    fn test_shard_pin_prevents_eviction() {
        let mut config = CacheConfig::default();
        config.max_size = 24;
        config.max_entries = 2;

        let shard = CacheShard::new(CachePolicy::Lru, config, 0);

        shard.put("key1".to_string(), 1, 8).unwrap();
        shard.put("key2".to_string(), 2, 8).unwrap();

        // Pin key1
        shard.pin(&"key1".to_string());

        // Try to insert key3 - should fail because key1 is pinned
        let result = shard.put("key3".to_string(), 3, 8);
        assert!(matches!(result, Err(CacheError::CacheFull)));

        // Unpin and retry
        shard.unpin(&"key1".to_string());
        shard.put("key3".to_string(), 3, 8).unwrap();
    }

    #[test]
    fn test_shard_clear() {
        let config = CacheConfig::default();
        let shard = CacheShard::new(CachePolicy::Lru, config, 0);

        shard.put("key1".to_string(), 1, 8).unwrap();
        shard.put("key2".to_string(), 2, 8).unwrap();

        let result = shard.clear();
        assert_eq!(result.entries_cleared, 2);
        assert_eq!(shard.stats.entry_count(), 0);
    }

    #[test]
    fn test_lfu_eviction() {
        let mut config = CacheConfig::default();
        config.max_size = 24;
        config.max_entries = 2;

        let shard = CacheShard::new(CachePolicy::Lfu, config, 0);

        shard.put("key1".to_string(), 1, 8).unwrap();
        shard.put("key2".to_string(), 2, 8).unwrap();

        // Access key1 multiple times to increase its frequency
        for _ in 0..5 {
            shard.get(&"key1".to_string());
        }

        // Insert key3 - should evict key2 (lower frequency)
        shard.put("key3".to_string(), 3, 8).unwrap();

        assert_eq!(shard.get(&"key2".to_string()), None);
        assert_eq!(shard.get(&"key1".to_string()), Some(1));
        assert_eq!(shard.get(&"key3".to_string()), Some(3));
    }
}
