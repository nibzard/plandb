# Code Review Cartridge Specification

## Purpose

Specialized cartridge for storing and querying code review notes. Links reviews to commits, files, symbols, and pull requests with efficient indexing for fast lookups.

## Types

### CodeReviewCartridge

**Description**: Main cartridge for code review storage

**Fields**:
- `allocator: Allocator` - Memory allocator
- `event_manager: EventManager` - Event manager for persistence

**Invariants**:
- Event manager is valid for lifetime of cartridge
- All reviews are stored as events in event store

### ReviewNote

**Description**: Individual review note

**Fields**:
- `event_id: u64` - Unique event identifier
- `author: u64` - Author ID (agent or human)
- `target_type: String` - Type of target ("commit", "file", "symbol", "pr")
- `target_id: String` - Target identifier (hash, path, name)
- `note_text: String` - Review note content
- `visibility: EventVisibility` - Who can see this review
- `timestamp: i64` - When review was created
- `references: Vec<String>` - Related item references

**Invariants**:
- `target_type` is one of: "commit", "file", "symbol", "pr"
- `note_text` is non-empty
- `timestamp` is monotonically increasing for new notes

### ReviewTargetType (Enum)

**Description**: Type of review target

**Variants**:
- `Commit` - Git commit
- `File` - Source file
- `Symbol` - Code symbol (function, struct, etc.)
- `PullRequest` - Pull/merge request

## Functions

### CodeReviewCartridge::new(event_manager: EventManager) -> Self

**Purpose**: Create new code review cartridge

**Algorithm**:
1. Create cartridge with event manager reference
2. Return instance

### CodeReviewCartridge::add_review_note(&mut self, author: u64, target_type: &str, target_id: &str, note_text: &str, visibility: EventVisibility, references: Vec<String>) -> Result<u64, Error>

**Purpose**: Add a review note for a target

**Algorithm**:
1. Validate target_type is valid
2. Validate note_text is non-empty
3. Record review via event_manager.recordReviewNote()
4. Return event ID

**Error Conditions**:
- `Error::InvalidTargetType`: target_type not recognized
- `Error::EmptyNoteText`: note_text is empty

### CodeReviewCartridge::get_review_notes(&self, target_type: &str, target_id: &str) -> Result<Vec<ReviewNote>, Error>

**Purpose**: Get review notes for a specific target

**Algorithm**:
1. Query all review_note events
2. Deserialize each payload
3. Filter by target_type and target_id
4. Return matching notes

### CodeReviewCartridge::get_commit_reviews(&self, commit_hash: &str) -> Result<Vec<ReviewNote>, Error>

**Purpose**: Get reviews for a specific commit

**Algorithm**: Shortcut to `get_review_notes("commit", commit_hash)`

### CodeReviewCartridge::get_file_reviews(&self, file_path: &str) -> Result<Vec<ReviewNote>, Error>

**Purpose**: Get reviews for a specific file

**Algorithm**: Shortcut to `get_review_notes("file", file_path)`

### CodeReviewCartridge::get_symbol_reviews(&self, symbol_name: &str) -> Result<Vec<ReviewNote>, Error>

**Purpose**: Get reviews for a specific symbol

**Algorithm**: Shortcut to `get_review_notes("symbol", symbol_name)`

### CodeReviewCartridge::get_reviews_by_author(&self, author_id: u64, limit: Option<usize>) -> Result<Vec<ReviewNote>, Error>

**Purpose**: Get reviews by a specific author

**Algorithm**:
1. Get events by actor from event manager
2. Filter for review_note type
3. Deserialize each payload
4. Return matching notes (respect limit)

### CodeReviewCartridge::get_all_reviews(&self, limit: Option<usize>) -> Result<Vec<ReviewNote>, Error>

**Purpose**: Get all review notes

**Algorithm**:
1. Query review_note events with limit
2. Deserialize each payload
3. Return all notes

### CodeReviewCartridge::get_reviews_in_date_range(&self, start: i64, end: i64) -> Result<Vec<ReviewNote>, Error>

**Purpose**: Get reviews within a date range

**Algorithm**:
1. Query events with start_time and end_time
2. Filter for review_note type
3. Deserialize each payload
4. Return matching notes

## Payload Format

Review notes are serialized in event payloads as:

```
[target_type]\0[target_id]\0[note_text]
```

Where `\0` is null byte separator.

## Dependencies

- **Uses**: Event system (EventManager, EventType, EventVisibility)
- **Used by**: Plugin system (review hooks), query system

## Rust Implementation Guidance

### Module Structure

```
northstar-ai/cartridges/
  code_review.rs      - CodeReviewCartridge implementation
```

### Type Definitions

- **CodeReviewCartridge**: Struct with EventManager reference
- **ReviewNote**: Struct with all fields
- **ReviewTargetType**: Enum with variants

### Concurrency

- **CodeReviewCartridge**: Not thread-safe by default
- Use `Arc<RwLock<CodeReviewCartridge>>` for shared access
- All reads are `&self`, mutations are `&mut self`

### Key Decisions

- **Storage**: Delegated to event system for simplicity
- **Payload format**: Null-byte separated for compact storage
- **Querying**: Filter in-memory for simplicity (can optimize with indexes later)

### Implementation Notes

1. Implement `From<EventResult>` for ReviewNote for conversion
2. Use `Cow<str>` for borrowed string references
3. Add builder pattern for ReviewNote construction
4. Implement `Display` for ReviewNote for debugging

### Testing Strategy

**Unit tests for**:
- Add review note
- Get reviews by target type
- Get reviews by author
- Date range queries
- Empty result handling

**Property tests for**:
- Review ID uniqueness
- Timestamp monotonicity

**Integration scenarios**:
- Multi-file reviews
- Cross-reference resolution
- Large review collections
