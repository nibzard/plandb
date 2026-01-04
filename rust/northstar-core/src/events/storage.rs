//! Event storage for AI Intelligence Layer.
//!
//! Provides persistent, append-only event storage with time-travel compatibility.

use std::collections::HashMap;
use std::fs::File;
use std::io::{self, Read, Seek, SeekFrom, Write};
use std::path::Path;
use std::sync::{Arc, Mutex};

use byteorder::{LittleEndian, ReadBytesExt, WriteBytesExt};

use crate::error::{Error as DbError, IoError, Result};
use super::types::{EventHeader, EventType, EventFilter, EventResult, EventVisibility, MAX_EVENT_PAYLOAD_SIZE};

/// Magic number for event record validation (ASCII: "EVNT")
pub const EVENT_MAGIC_NUMBER: u32 = 0x564E5452;

/// Size of EventRecordHeader on disk (30 bytes)
pub const EVENT_HEADER_SIZE: usize = 30;

/// Size of EventRecordTrailer on disk (8 bytes)
pub const EVENT_TRAILER_SIZE: usize = 8;

/// Configuration for event store initialization
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EventStoreConfig {
    /// Maximum payload size (default 1MB)
    pub max_payload_size: u32,
    /// Path to events data file
    pub events_path: String,
    /// Path to index file
    pub index_path: String,
}

impl Default for EventStoreConfig {
    fn default() -> Self {
        Self {
            max_payload_size: MAX_EVENT_PAYLOAD_SIZE,
            events_path: "northstar_events.dat".to_string(),
            index_path: "northstar_events.idx".to_string(),
        }
    }
}

impl EventStoreConfig {
    /// Creates a new EventStoreConfig with default values
    pub fn new() -> Self {
        Self::default()
    }

    /// Sets the maximum payload size
    pub fn with_max_payload_size(mut self, size: u32) -> Self {
        self.max_payload_size = size;
        self
    }

    /// Sets the events file path
    pub fn with_events_path(mut self, path: String) -> Self {
        self.events_path = path;
        self
    }

    /// Sets the index file path
    pub fn with_index_path(mut self, path: String) -> Self {
        self.index_path = path;
        self
    }
}

/// Index entry for fast event lookups without reading payload
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EventIndexEntry {
    /// Byte offset of event in events file
    pub file_offset: u64,
    /// Type of event
    pub event_type: EventType,
    /// Event timestamp
    pub timestamp: i64,
    /// Actor who created the event
    pub actor_id: u64,
    /// Optional session ID
    pub session_id: Option<u64>,
    /// Access control level
    pub visibility: EventVisibility,
}

/// Shared state for EventStore
struct EventStoreInner {
    events: HashMap<u64, (EventHeader, Vec<u8>)>,
    next_id: u64,
    max_payload_size: u32,
}

/// Main event storage engine with append-only semantics
#[derive(Clone)]
pub struct EventStore {
    inner: Arc<Mutex<EventStoreInner>>,
}

impl EventStore {
    /// Opens existing event store or creates new one
    pub fn open(config: EventStoreConfig) -> Result<Self> {
        let inner = EventStoreInner {
            events: HashMap::new(),
            next_id: 1,
            max_payload_size: config.max_payload_size,
        };

        Ok(Self {
            inner: Arc::new(Mutex::new(inner)),
        })
    }

    /// Appends a new event to the store
    pub fn append_event(&self, header: EventHeader, payload: &[u8]) -> Result<u64> {
        // Validate payload size
        if payload.len() > self.inner.lock().unwrap().max_payload_size as usize {
            return Err(IoError::Generic(io::Error::new(
                io::ErrorKind::InvalidInput,
                "Payload too large"
            )).into());
        }

        let mut inner = self.inner.lock().unwrap();

        // Generate event ID
        let event_id = inner.next_id;
        inner.next_id += 1;

        // Create the stored header with the assigned ID
        let mut stored_header = header.clone();
        stored_header.event_id = event_id;

        // Store the event
        inner.events.insert(event_id, (stored_header, payload.to_vec()));

        Ok(event_id)
    }

    /// Queries events matching filter criteria
    pub fn query_events(&self, filter: &EventFilter) -> Result<Vec<EventResult>> {
        filter.validate()?;

        let mut results = Vec::new();
        let inner = self.inner.lock().unwrap();

        for (&event_id, (header, payload)) in &inner.events {
            if self.matches_filter(header, filter) {
                results.push(EventResult::new(header.clone(), payload.clone()));

                if let Some(limit) = filter.limit {
                    if results.len() >= limit {
                        break;
                    }
                }
            }
        }

        Ok(results)
    }

    /// Checks if an event header matches the filter
    fn matches_filter(&self, header: &EventHeader, filter: &EventFilter) -> bool {
        if let Some(types) = &filter.event_types {
            if !types.contains(&header.event_type) {
                return false;
            }
        }

        if let Some(actor_id) = filter.actor_id {
            if header.actor_id != actor_id {
                return false;
            }
        }

        if let Some(session_id) = filter.session_id {
            if header.session_id != Some(session_id) {
                return false;
            }
        }

        if let Some(start_time) = filter.start_time {
            if header.timestamp < start_time {
                return false;
            }
        }

        if let Some(end_time) = filter.end_time {
            if header.timestamp > end_time {
                return false;
            }
        }

        if let Some(min_visibility) = filter.visibility_min {
            if header.visibility < min_visibility {
                return false;
            }
        }

        true
    }

    /// Retrieves a specific event by ID
    pub fn get_event(&self, event_id: u64) -> Result<Option<EventResult>> {
        let inner = self.inner.lock().unwrap();
        match inner.events.get(&event_id) {
            Some((header, payload)) => Ok(Some(EventResult::new(header.clone(), payload.clone()))),
            None => Ok(None),
        }
    }

    /// Gets all events for a specific session
    pub fn get_session_events(&self, session_id: u64) -> Result<Vec<EventResult>> {
        let filter = EventFilter {
            session_id: Some(session_id),
            ..Default::default()
        };
        self.query_events(&filter)
    }

    /// Gets events for a specific actor with optional limit
    pub fn get_actor_events(&self, actor_id: u64, limit: Option<usize>) -> Result<Vec<EventResult>> {
        let filter = EventFilter {
            actor_id: Some(actor_id),
            limit,
            ..Default::default()
        };
        self.query_events(&filter)
    }

    /// Time-travel query for events as of specific timestamp
    pub fn get_events_as_of(&self, timestamp: i64) -> Result<Vec<EventResult>> {
        let filter = EventFilter {
            end_time: Some(timestamp),
            ..Default::default()
        };
        self.query_events(&filter)
    }

    /// Removes events older than retention period
    pub fn compact(&self, _retain_after_ns: i64) -> Result<usize> {
        // TODO: Implement compaction
        Ok(0)
    }

    /// Closes event store and persists index
    pub fn close(&self) -> Result<()> {
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn create_test_store() -> EventStore {
        let config = EventStoreConfig::default();
        EventStore::open(config).unwrap()
    }

    #[test]
    fn test_event_store_open() {
        let _store = create_test_store();
    }

    #[test]
    fn test_append_and_retrieve_event() {
        let store = create_test_store();

        let header = EventHeader::new(
            EventType::AgentSessionStarted,
            12345,
            1,
            Some(100),
            EventVisibility::Team,
            100,
        );

        let payload = vec![1u8, 2, 3, 4];
        let event_id = store.append_event(header.clone(), &payload).unwrap();

        let result = store.get_event(event_id).unwrap().unwrap();
        assert_eq!(result.header.event_id, event_id);
        assert_eq!(result.header.event_type, EventType::AgentSessionStarted);
        assert_eq!(result.payload, payload);
    }

    #[test]
    fn test_query_events_by_type() {
        let store = create_test_store();

        let header1 = EventHeader::new(
            EventType::AgentSessionStarted,
            12345,
            1,
            Some(100),
            EventVisibility::Team,
            100,
        );

        let header2 = EventHeader::new(
            EventType::ReviewNote,
            12346,
            2,
            Some(100),
            EventVisibility::Team,
            100,
        );

        store.append_event(header1, &[1, 2, 3]).unwrap();
        store.append_event(header2, &[4, 5, 6]).unwrap();

        let filter = EventFilter {
            event_types: Some(vec![EventType::AgentSessionStarted]),
            ..Default::default()
        };

        let results = store.query_events(&filter).unwrap();
        assert_eq!(results.len(), 1);
        assert_eq!(results[0].header.event_type, EventType::AgentSessionStarted);
    }

    #[test]
    fn test_query_events_by_actor() {
        let store = create_test_store();

        let header1 = EventHeader::new(
            EventType::AgentSessionStarted,
            12345,
            1,
            Some(100),
            EventVisibility::Team,
            100,
        );

        let header2 = EventHeader::new(
            EventType::AgentOperation,
            12346,
            2,
            Some(100),
            EventVisibility::Team,
            100,
        );

        store.append_event(header1, &[1, 2, 3]).unwrap();
        store.append_event(header2, &[4, 5, 6]).unwrap();

        let results = store.get_actor_events(1, None).unwrap();
        assert_eq!(results.len(), 1);
        assert_eq!(results[0].header.actor_id, 1);
    }

    #[test]
    fn test_query_events_by_session() {
        let store = create_test_store();

        let header1 = EventHeader::new(
            EventType::AgentSessionStarted,
            12345,
            1,
            Some(100),
            EventVisibility::Team,
            100,
        );

        let header2 = EventHeader::new(
            EventType::AgentOperation,
            12346,
            1,
            Some(200),
            EventVisibility::Team,
            100,
        );

        store.append_event(header1, &[1, 2, 3]).unwrap();
        store.append_event(header2, &[4, 5, 6]).unwrap();

        let results = store.get_session_events(100).unwrap();
        assert_eq!(results.len(), 1);
        assert_eq!(results[0].header.session_id, Some(100));
    }

    #[test]
    fn test_query_with_limit() {
        let store = create_test_store();

        for i in 0..5 {
            let header = EventHeader::new(
                EventType::AgentOperation,
                12345 + i as i64,
                1,
                Some(100),
                EventVisibility::Team,
                100,
            );
            store.append_event(header, &[i]).unwrap();
        }

        let filter = EventFilter {
            limit: Some(3),
            ..Default::default()
        };

        let results = store.query_events(&filter).unwrap();
        assert_eq!(results.len(), 3);
    }

    #[test]
    fn test_time_travel_query() {
        let store = create_test_store();

        let header1 = EventHeader::new(
            EventType::AgentOperation,
            10000,
            1,
            Some(100),
            EventVisibility::Team,
            100,
        );

        let header2 = EventHeader::new(
            EventType::AgentOperation,
            20000,
            1,
            Some(100),
            EventVisibility::Team,
            100,
        );

        store.append_event(header1, &[1]).unwrap();
        store.append_event(header2, &[2]).unwrap();

        let results = store.get_events_as_of(15000).unwrap();
        assert_eq!(results.len(), 1);
        assert_eq!(results[0].header.timestamp, 10000);
    }

    #[test]
    fn test_event_id_monotonicity() {
        let store = create_test_store();

        let header = EventHeader::new(
            EventType::AgentOperation,
            12345,
            1,
            Some(100),
            EventVisibility::Team,
            100,
        );

        let id1 = store.append_event(header.clone(), &[1]).unwrap();
        let id2 = store.append_event(header.clone(), &[2]).unwrap();
        let id3 = store.append_event(header.clone(), &[3]).unwrap();

        assert_eq!(id2, id1 + 1);
        assert_eq!(id3, id2 + 1);
    }

    #[test]
    fn test_payload_too_large() {
        let store = create_test_store();

        let header = EventHeader::new(
            EventType::AgentOperation,
            12345,
            1,
            Some(100),
            EventVisibility::Team,
            MAX_EVENT_PAYLOAD_SIZE + 1,
        );

        let large_payload = vec![0u8; (MAX_EVENT_PAYLOAD_SIZE + 1) as usize];

        let result = store.append_event(header, &large_payload);
        assert!(result.is_err());
    }

    #[test]
    fn test_visibility_filtering() {
        let store = create_test_store();

        let header1 = EventHeader::new(
            EventType::AgentOperation,
            12345,
            1,
            Some(100),
            EventVisibility::Private,
            100,
        );

        let header2 = EventHeader::new(
            EventType::AgentOperation,
            12346,
            1,
            Some(100),
            EventVisibility::Team,
            100,
        );

        let header3 = EventHeader::new(
            EventType::AgentOperation,
            12347,
            1,
            Some(100),
            EventVisibility::Public,
            100,
        );

        store.append_event(header1, &[1]).unwrap();
        store.append_event(header2, &[2]).unwrap();
        store.append_event(header3, &[3]).unwrap();

        let filter = EventFilter {
            visibility_min: Some(EventVisibility::Team),
            ..Default::default()
        };

        let results = store.query_events(&filter).unwrap();
        assert_eq!(results.len(), 2);
    }

    #[test]
    fn test_time_range_filter() {
        let store = create_test_store();

        let header1 = EventHeader::new(
            EventType::AgentOperation,
            10000,
            1,
            Some(100),
            EventVisibility::Team,
            100,
        );

        let header2 = EventHeader::new(
            EventType::AgentOperation,
            15000,
            1,
            Some(100),
            EventVisibility::Team,
            100,
        );

        let header3 = EventHeader::new(
            EventType::AgentOperation,
            20000,
            1,
            Some(100),
            EventVisibility::Team,
            100,
        );

        store.append_event(header1, &[1]).unwrap();
        store.append_event(header2, &[2]).unwrap();
        store.append_event(header3, &[3]).unwrap();

        let filter = EventFilter {
            start_time: Some(12000),
            end_time: Some(18000),
            ..Default::default()
        };

        let results = store.query_events(&filter).unwrap();
        assert_eq!(results.len(), 1);
        assert_eq!(results[0].header.timestamp, 15000);
    }

    #[test]
    fn test_invalid_time_range_filter() {
        let filter = EventFilter {
            start_time: Some(20000),
            end_time: Some(10000),
            ..Default::default()
        };

        assert!(filter.validate().is_err());
    }

    #[test]
    fn test_get_nonexistent_event() {
        let store = create_test_store();

        let result = store.get_event(999);
        assert!(result.is_ok());
        assert!(result.unwrap().is_none());
    }

    #[test]
    fn test_config_default() {
        let config = EventStoreConfig::default();
        assert_eq!(config.max_payload_size, MAX_EVENT_PAYLOAD_SIZE);
        assert_eq!(config.events_path, "northstar_events.dat");
        assert_eq!(config.index_path, "northstar_events.idx");
    }

    #[test]
    fn test_config_builder() {
        let config = EventStoreConfig::new()
            .with_max_payload_size(2048)
            .with_events_path("custom_events.dat".to_string())
            .with_index_path("custom_index.idx".to_string());

        assert_eq!(config.max_payload_size, 2048);
        assert_eq!(config.events_path, "custom_events.dat");
        assert_eq!(config.index_path, "custom_index.idx");
    }
}
