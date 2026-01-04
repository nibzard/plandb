# Event Storage for AI Intelligence Layer

## Purpose

Provides persistent, append-only event storage with time-travel compatibility. Events are stored separately from the main database to avoid impacting hot path performance while maintaining efficient query capabilities for observability and review workflows.

## Types

### EventStore

**Description**: Main event storage engine with append-only semantics

**Fields**:
- `allocator: Allocator` - Memory allocator for dynamic allocations
- `events_file: File` - File handle for events data storage
- `index_file: File` - File handle for in-memory index persistence
- `next_event_id: u64` - Next event ID to assign (monotonic)
- `index: HashMap<u64, EventIndexEntry>` - In-memory index for fast lookups
- `max_payload_size: u32` - Maximum allowed payload size

**Invariants**:
- `next_event_id` is always greater than any assigned event ID
- `index` contains entries for all persisted events
- File positions in `index` point to valid event records
- `events_file` and `index_file` remain open for the lifetime of EventStore

### EventIndexEntry

**Description**: Index entry for fast event lookups without reading payload

**Fields**:
- `file_offset: u64` - Byte offset of event in events file
- `event_type: EventType` - Type of event
- `timestamp: i64` - Event timestamp
- `actor_id: u64` - Actor who created the event
- `session_id: Option<u64>` - Optional session ID
- `visibility: EventVisibility` - Access control level

**Size**: 35 bytes (8 + 2 + 8 + 8 + 1 + 8 + 1)

**Invariants**: `file_offset` points to a valid event record in the events file

### EventRecordHeader

**Description**: On-disk header for event records (internal to storage)

**Fields**:
- `event_id: u64` - Unique event identifier
- `event_type: u16` - Event type as integer
- `timestamp: i64` - Unix nanosecond timestamp
- `actor_id: u64` - Actor identifier
- `payload_len: u32` - Payload size in bytes

**Size**: 30 bytes

**Alignment**: 8-byte aligned

**Invariants**: `payload_len <= max_payload_size`

### EventRecordTrailer

**Description**: On-disk trailer for event record validation

**Fields**:
- `magic: u32` - Magic number 0x564E5452 ("EVNT" in ASCII)
- `total_len: u32` - Total record size including header, payload, trailer

**Size**: 8 bytes

**Invariants**: `magic` must be 0x564E5452 for valid records

### EventStoreConfig

**Description**: Configuration for event store initialization

**Fields**:
- `max_payload_size: u32` - Maximum payload size (default 1MB)
- `events_path: String` - Path to events data file (default "northstar_events.dat")
- `index_path: String` - Path to index file (default "northstar_events.idx")

**Default Values**:
- `max_payload_size`: 1,048,576 (1 MB)
- `events_path`: "northstar_events.dat"
- `index_path`: "northstar_events.idx"

## Constants

### EVENT_HEADER_SIZE

**Value**: 30 bytes

**Purpose**: Size of EventRecordHeader on disk

### EVENT_TRAILER_SIZE

**Value**: 8 bytes

**Purpose**: Size of EventRecordTrailer on disk

### EVENT_MAGIC_NUMBER

**Value**: 0x564E5452

**Purpose**: Magic number for event record validation (ASCII: "EVNT")

## On-Disk Format

### Event Record Layout

Each event is stored as a contiguous record:

```
[EventRecordHeader: 30 bytes]
[Payload: N bytes (payload_len)]
[EventRecordTrailer: 8 bytes]
```

Total record size: 38 + N bytes

### Index File Format

Index entries are stored sequentially:

```
[event_id: u8][file_offset: u8][event_type: u2][timestamp: i8]
[actor_id: u8][session_id_raw: u8][visibility: u1]
```

Each entry: 43 bytes (8+8+2+8+8+8+1)

Special encoding: `session_id_raw = 0` means `None`, otherwise contains the session ID

## Functions

### EventStore::open(config: EventStoreConfig) -> Result<Self, Error>

**Purpose**: Opens existing event store or creates new one

**Returns**: EventStore instance ready for operations

**Algorithm**:
1. Open events file, create if not exists (read-write mode)
2. Open index file, create if not exists (read-write mode)
3. Initialize EventStore with config values
4. Load existing index from index file if present
5. If events file has data, scan to find highest event ID
6. Set `next_event_id = max_event_id + 1`

**Error Conditions**:
- `Error::Io`: File open/creation failed
- `Error::CorruptIndex`: Index file format is invalid
- `Error::CorruptEvent`: Events file contains invalid records

**Concurrency**: Not thread-safe, requires external synchronization

### EventStore::deinit(&mut self)

**Purpose**: Closes event store and persists index

**Algorithm**:
1. Save in-memory index to index file
2. Deallocate index hashmap
3. Close events file
4. Close index file

**Error Handling**: Errors during index save are silently ignored (best-effort persistence)

### EventStore::append_event(&mut self, event: EventHeader, payload: &[u8]) -> Result<u64, Error>

**Purpose**: Appends a new event to the store

**Returns**: Assigned event ID

**Algorithm**:
1. Validate payload size against `max_payload_size`
2. Generate event ID from `next_event_id` and increment
3. Update event header with assigned ID
4. Validate event header
5. Calculate total record size: header + payload + trailer
6. Seek to end of events file
7. Write EventRecordHeader
8. Write payload bytes
9. Write EventRecordTrailer
10. Insert entry into in-memory index

**Error Conditions**:
- `Error::PayloadTooLarge`: Payload exceeds maximum size
- `Error::InvalidHeader`: Event header validation failed
- `Error::Io`: Write operation failed

**Concurrency**: Requires exclusive write access

### EventStore::query_events(&self, filter: EventFilter) -> Result<Vec<EventResult>, Error>

**Purpose**: Queries events matching filter criteria

**Returns**: Vector of matching events with headers and payloads

**Algorithm**:
1. Initialize empty results vector
2. Iterate over all index entries
3. For each entry, apply all filter conditions:
   - Check event_types if specified
   - Check actor_id if specified
   - Check session_id if specified
   - Check time range (start_time, end_time)
   - Check visibility minimum
4. If all conditions pass, read event payload from file
5. Create EventResult with header and payload
6. Append to results
7. Stop if limit is reached
8. Return results

**Error Conditions**:
- `Error::Io`: Read operation failed
- `Error::CorruptEvent`: Event record is corrupted (skipped, not returned)

**Concurrency**: Read-only, safe for concurrent reads

### EventStore::get_event(&self, event_id: u64) -> Result<Option<EventResult>, Error>

**Purpose**: Retrieves a specific event by ID

**Returns**: EventResult if found, None if not found

**Algorithm**:
1. Look up event_id in index
2. If not found, return None
3. Read event payload from file offset in index entry
4. Construct EventResult with header and payload
5. Return Some(result)

**Error Conditions**:
- `Error::Io`: Read operation failed
- `Error::CorruptEvent`: Event record is corrupted

**Concurrency**: Read-only, safe for concurrent reads

### EventStore::get_session_events(&self, session_id: u64) -> Result<Vec<EventResult>, Error>

**Purpose**: Gets all events for a specific session

**Returns**: All events associated with the session

**Algorithm**: Shortcut to `query_events` with `EventFilter { session_id: Some(session_id), ..default() }`

**Concurrency**: Read-only, safe for concurrent reads

### EventStore::get_actor_events(&self, actor_id: u64, limit: Option<usize>) -> Result<Vec<EventResult>, Error>

**Purpose**: Gets events for a specific actor with optional limit

**Returns**: Events created by the actor

**Algorithm**: Shortcut to `query_events` with `EventFilter { actor_id: Some(actor_id), limit, ..default() }`

**Concurrency**: Read-only, safe for concurrent reads

### EventStore::get_events_as_of(&self, timestamp: i64) -> Result<Vec<EventResult>, Error>

**Purpose**: Time-travel query for events as of specific timestamp

**Returns**: All events with timestamp <= specified timestamp

**Algorithm**: Shortcut to `query_events` with `EventFilter { end_time: Some(timestamp), ..default() }`

**Concurrency**: Read-only, safe for concurrent reads

### EventStore::compact(&mut self, retain_after_ns: i64) -> Result<(), Error>

**Purpose**: Removes events older than retention period

**Algorithm**:
1. Calculate cutoff timestamp: `now - retain_after_ns`
2. Collect all event IDs with timestamp < cutoff
3. Remove collected IDs from in-memory index
4. Rebuild storage files from remaining index entries

**Error Conditions**:
- `Error::Io`: File operations failed

**Concurrency**: Requires exclusive access

### EventStore::read_event_payload(&self, file_offset: u64) -> Result<Vec<u8>, Error>

**Purpose**: Private method to read event payload from file

**Returns**: Payload bytes

**Algorithm**:
1. Read EventRecordHeader at file_offset
2. Validate header.payload_len <= max_payload_size
3. Read payload bytes (header.payload_len)
4. Read EventRecordTrailer after payload
5. Validate trailer.magic == EVENT_MAGIC_NUMBER
6. Return payload bytes

**Error Conditions**:
- `Error::CorruptEvent`: Header/trailer validation failed
- `Error::PayloadTooLarge`: Payload size exceeds maximum
- `Error::Io`: Read operation failed

**Concurrency**: Read-only

### EventStore::scan_highest_event_id(&self) -> Result<u64, Error>

**Purpose**: Scans events file to find highest event ID

**Returns**: Highest event ID found + 1 (for next_event_id)

**Algorithm**:
1. Initialize max_id = 0, file_pos = 0
2. While file_pos < file_size:
   - Read EventRecordHeader at file_pos
   - Calculate trailer offset: file_pos + header_size + payload_len
   - Read EventRecordTrailer at trailer offset
   - Validate magic number
   - If valid, update max_id = max(max_id, header.event_id)
   - Advance file_pos by record size
   - If invalid, break (corrupt record, stop scanning)
3. Return max_id + 1

**Error Conditions**:
- `Error::CorruptEvent`: Invalid record encountered

**Concurrency**: Read-only

### EventStore::load_index(&mut self) -> Result<(), Error>

**Purpose**: Loads in-memory index from index file

**Algorithm**:
1. Get index file size
2. If empty, return success
3. Validate size is multiple of entry size (43 bytes)
4. While offset < file_size:
   - Read event_id, file_offset, event_type, timestamp, actor_id
   - Read session_id_raw (0 means None)
   - Read visibility
   - Insert into in-memory index

**Error Conditions**:
- `Error::CorruptIndex`: Index file size is not valid
- `Error::Io`: Read operation failed

**Concurrency**: Requires exclusive access during initialization

### EventStore::save_index(&self) -> Result<(), Error>

**Purpose**: Persists in-memory index to index file

**Algorithm**:
1. Truncate index file to 0 bytes
2. Seek to start of index file
3. For each index entry:
   - Serialize event_id, file_offset, event_type, timestamp, actor_id
   - Serialize session_id (0 if None)
   - Serialize visibility
   - Write all fields to file
4. Sync file to storage

**Error Conditions**:
- `Error::Io`: Write or sync operation failed

**Concurrency**: Requires exclusive access

### EventStore::rebuild_storage(&mut self) -> Result<(), Error>

**Purpose**: Rebuilds storage files removing gaps from deleted events

**Algorithm**:
1. Create temporary events file and index file
2. Create new empty index hashmap
3. For each entry in current index:
   - Read event payload from current file
   - Write to temporary events file
   - Update file offset to new position
   - Insert into new index
4. Sync and close temporary files
5. Close current events and index files
6. Replace current files with temporary files (rename)
7. Reopen files at original paths
8. Replace in-memory index with new index

**Error Conditions**:
- `Error::Io`: File operations failed

**Concurrency**: Requires exclusive access

## Dependencies

- **Uses**: Event types (EventType, EventHeader, EventFilter, EventResult)
- **Used by**: EventManager, plugin system, analytics engine

## Rust Implementation Guidance

### Module Structure

```
northstar-ai/events/
  storage.rs     - EventStore implementation
```

### Type Definitions

- **EventStore**: Struct with fields as specified
- **EventIndexEntry**: Struct with `#[repr(C)]` for predictable layout
- **EventRecordHeader/Trailer**: Internal structs with `#[repr(C)]`
- **File handles**: Use `std::fs::File` for file operations
- **Index**: Use `std::collections::HashMap<u64, EventIndexEntry>`

### Concurrency

- **EventStore is NOT Send/Sync**: Requires external synchronization
- Use `Arc<Mutex<EventStore>>` or `Arc<RwLock<EventStore>>` for shared access
- Prefer `RwLock` for read-heavy workloads (queries > appends)
- All public methods take `&self` or `&mut self` appropriately

### Key Decisions

- **File I/O**: Use buffered I/O with `BufReader`/`BufWriter` for performance
- **Index persistence**: Binary format for compact representation
- **Error handling**: Use `thiserror` for custom error types
- **Payload ownership**: Return `Vec<u8>` for owned payload data

### Implementation Notes

1. Implement `Drop` for EventStore to auto-save index on drop
2. Use `std::io::{Read, Write, Seek}` traits for file operations
3. Consider memory-mapped files for large event stores (optional optimization)
4. Implement batch append for multiple events (atomic batch operation)
5. Add checksum validation for corrupt event detection

### Testing Strategy

**Unit tests needed for**:
- EventStore creation and initialization
- Single event append and retrieval
- Event query with various filter combinations
- Session and actor event retrieval
- Time-travel queries
- Index persistence across reopen
- Compaction removes old events

**Property tests for**:
- Round-trip: append -> query -> verify payload
- Event ID monotonicity (always increasing)
- Index consistency with events file

**Integration scenarios**:
- Reopen store after crash, verify index recovery
- Concurrent reads with single writer
- Large event store with millions of events

### Performance Considerations

1. **Index size**: O(number of events), plan for memory limits
2. **Query performance**: O(N) scan of index, consider secondary indexes
3. **Append latency**: Single seek + write, should be sub-millisecond
4. **Compaction**: Rebuilds entire file, schedule during idle time
