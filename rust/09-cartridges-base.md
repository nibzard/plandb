# Structured Memory Cartridges - Base Types

## Purpose

Base cartridge types for structured memory storage. Cartridges provide type-safe storage for entities, topics, relationships, and specialized data structures used by AI operations.

## Core Concept

Cartridges are specialized data structures that extend the database with AI-relevant storage patterns. Each cartridge type has a specific purpose and access pattern optimized for AI operations like entity extraction, semantic search, and relationship traversal.

## Types

### CartridgeType (Enum)

**Description**: Type identifiers for different cartridges

**Variants**:
- `Entity` - Entity storage cartridge
- `Topic` - Topic/category storage cartridge
- `Relationship` - Relationship graph cartridge
- `Vector` - Vector embedding storage cartridge
- `CodeReview` - Code review storage cartridge
- `Observability` - Metrics and events cartridge
- `Temporal` - Time-series snapshot cartridge
- `PendingTasks` - Task queue cartridge

### EntityId

**Description**: Unique identifier for entities

**Representation**: Newtype wrapper around `String`

**Format**: `{namespace}:{local_id}`

**Examples**:
- "file:src/main.rs"
- "symbol:my_crate::MyStruct"
- "commit:abc123def"

**Invariants**: Contains exactly one colon separating namespace from local ID

### Entity

**Description**: Core entity representation

**Fields**:
- `id: EntityId` - Unique entity identifier
- `entity_type: String` - Type of entity (file, symbol, commit, etc.)
- `name: String` - Human-readable name
- `attributes: HashMap<String, Value>` - Entity attributes
- `embeddings: Option<Vec<f32>>` - Optional vector embedding
- `created_at: i64` - Creation timestamp
- `updated_at: i64` - Last update timestamp
- `version: u64` - Monotonically increasing version

**Invariants**:
- `created_at <= updated_at`
- `version` increases on each update
- `entity_type` is non-empty

### Topic

**Description**: Topic/category for grouping related entities

**Fields**:
- `id: String` - Unique topic identifier
- `name: String` - Topic name
- `description: String` - Topic description
- `parent_id: Option<String>` - Parent topic (for hierarchy)
- `entity_ids: Vec<EntityId>` - Entities in this topic
- `metadata: HashMap<String, Value>` - Additional metadata
- `created_at: i64` - Creation timestamp

**Invariants**:
- `name` is non-empty
- No circular parent references

### Relationship

**Description**: Relationship between two entities

**Fields**:
- `id: String` - Unique relationship identifier
- `from_entity: EntityId` - Source entity
- `to_entity: EntityId` - Target entity
- `relationship_type: String` - Type of relationship
- `attributes: HashMap<String, Value>` - Relationship attributes
- `weight: f32` - Relationship strength (0.0 to 1.0)
- `created_at: i64` - Creation timestamp

**Invariants**:
- `from_entity != to_entity` (no self-relationships)
- `weight` in range [0.0, 1.0]
- `relationship_type` is non-empty

### VectorEmbedding

**Description**: Vector embedding for semantic search

**Fields**:
- `entity_id: EntityId` - Associated entity
- `vector: Vec<f32>` - Embedding vector
- `model_id: String` - Model used to generate embedding
- `dimension: usize` - Vector dimension
- `created_at: i64` - Creation timestamp

**Invariants**:
- `vector.len() == dimension`
- `dimension` matches model's expected dimension

### SnapshotMetadata

**Description**: Metadata for temporal snapshots

**Fields**:
- `entity_namespace: String` - Entity namespace
- `entity_id: String` - Entity identifier
- `version: u64` - Snapshot version
- `has_delta: bool` - Whether this is a delta snapshot
- `created_at: i64` - Snapshot timestamp

### FieldDeltaResult

**Description**: Result of field-level delta computation

**Fields**:
- `operation: DeltaOperation` - Type of change
- `field_name: String` - Changed field
- `old_value: Option<Value>` - Previous value
- `new_value: Option<Value>` - New value

### DeltaOperation

**Description**: Type of delta operation

**Variants**:
- `Added` - Field was added
- `Modified` - Field was changed
- `Removed` - Field was deleted
- `Unchanged` - Field is the same

## Cartridge Traits

### Cartridge

**Description**: Base trait for all cartridges

**Required Methods**:
- `name(&self) -> &str` - Cartridge name
- `initialize(&mut self) -> Result<(), Error>` - Initialize cartridge
- `cleanup(&mut self) -> Result<(), Error>` - Cleanup resources

**Optional Methods**:
- `query(&self, query: CartridgeQuery) -> Result<Vec<CartridgeResult>, Error>` - Query cartridge
- `insert(&mut self, data: CartridgeData) -> Result<(), Error>` - Insert data
- `update(&mut self, id: &str, data: CartridgeData) -> Result<(), Error>` - Update data
- `delete(&mut self, id: &str) -> Result<(), Error>` - Delete data

### EntityCartridge

**Description**: Trait for entity storage cartridges

**Extends**: `Cartridge`

**Required Methods**:
- `get_entity(&self, id: &EntityId) -> Result<Option<Entity>, Error>` - Get entity by ID
- `list_entities(&self, entity_type: &str) -> Result<Vec<Entity>, Error>` - List entities by type
- `search_entities(&self, query: &str) -> Result<Vec<Entity>, Error>` - Full-text search
- `update_entity(&mut self, entity: Entity) -> Result<(), Error>` - Update entity

### TopicCartridge

**Description**: Trait for topic storage cartridges

**Extends**: `Cartridge`

**Required Methods**:
- `get_topic(&self, id: &str) -> Result<Option<Topic>, Error>` - Get topic by ID
- `list_topics(&self) -> Result<Vec<Topic>, Error>` - List all topics
- `get_topic_entities(&self, topic_id: &str) -> Result<Vec<Entity>, Error>` - Get entities in topic
- `add_entity_to_topic(&mut self, topic_id: &str, entity_id: &EntityId) -> Result<(), Error>` - Add entity to topic

### RelationshipCartridge

**Description**: Trait for relationship graph cartridges

**Extends**: `Cartridge`

**Required Methods**:
- `get_relationships(&self, entity: &EntityId) -> Result<Vec<Relationship>, Error>` - Get relationships for entity
- `add_relationship(&mut self, relationship: Relationship) -> Result<(), Error>` - Add relationship
- `find_path(&self, from: &EntityId, to: &EntityId) -> Result<Vec<EntityId>, Error>` - Find path between entities

### VectorCartridge

**Description**: Trait for vector embedding cartridges

**Extends**: `Cartridge`

**Required Methods**:
- `insert_embedding(&mut self, embedding: VectorEmbedding) -> Result<(), Error>` - Insert embedding
- `similarity_search(&self, vector: &[f32], limit: usize) -> Result<Vec<SimilarityResult>, Error>` - Find similar vectors
- `get_embedding(&self, entity_id: &EntityId) -> Result<Option<VectorEmbedding>, Error>` - Get embedding for entity

### SimilarityResult

**Description**: Result from similarity search

**Fields**:
- `entity_id: EntityId` - Matching entity
- `similarity: f32` - Similarity score (0.0 to 1.0)
- `vector: Vec<f32>` - Matching vector

**Invariants**: `similarity` in range [0.0, 1.0]

## Query Types

### CartridgeQuery

**Description**: Generic query for cartridges

**Fields**:
- `filter: Option<QueryFilter>` - Filter conditions
- `limit: Option<usize>` - Result limit
- `offset: Option<usize>` - Result offset
- `order_by: Option<String>` - Sort field
- `order: OrderDirection` - Sort direction

### OrderDirection

**Description**: Sort direction

**Variants**:
- `Asc` - Ascending order
- `Desc` - Descending order

### QueryFilter

**Description**: Filter condition for queries

**Fields**:
- `field: String` - Field to filter on
- `operator: FilterOperator` - Comparison operator
- `value: Value` - Value to compare against

### FilterOperator

**Description**: Comparison operator

**Variants**:
- `Equal` - Exact match
- `NotEqual` - Not equal
- `GreaterThan` - Greater than
- `LessThan` - Less than
- `Contains` - String contains
- `StartsWith` - String starts with
- `EndsWith` - String ends with

## Dependencies

- **Uses**: Event system, LLM types
- **Used by**: Specific cartridge implementations, AI operations

## Rust Implementation Guidance

### Module Structure

```
northstar-ai/cartridges/
  mod.rs              - Public API
  base.rs             - Base traits and types
  entity.rs           - Entity cartridge
  topic.rs            - Topic cartridge
  relationship.rs     - Relationship cartridge
  vector.rs           - Vector cartridge
  code_review.rs      - Code review cartridge
  observability.rs    - Observability cartridge
```

### Type Definitions

- **EntityId**: Newtype `struct EntityId(String)`
- **Entity**: Struct with HashMap for attributes
- **Cartridge**: Trait with required and optional methods
- **Value**: Use `serde_json::Value`

### Concurrency

- **Cartridge traits**: No implicit thread safety
- Implementations use `Arc<RwLock<Cartridge>>` for shared access
- Query operations should be `&self` (read-only)
- Mutations use `&mut self` (exclusive access)

### Key Decisions

- **Trait vs Enum**: Use traits for extensibility
- **ID format**: String with colon separator for readability
- **Attributes**: Use `HashMap<String, serde_json::Value>` for flexibility
- **Embeddings**: Use `Vec<f32>` for compatibility with ML libraries

### Implementation Notes

1. Implement `Display` for EntityId
2. Use `derive(Debug, Clone)` for data types
3. Implement `PartialEq` for EntityId, Value types
4. Add builder pattern for complex queries
5. Use `Arc<str>` for string deduplication

### Testing Strategy

**Unit tests for**:
- Entity ID parsing and validation
- Entity attribute operations
- Relationship creation and validation
- Vector similarity computation

**Property tests for**:
- Entity version monotonicity
- Relationship weight bounds
- Snapshot metadata consistency

**Integration scenarios**:
- Multi-cartridge queries
- Cross-cartridge references
- Snapshot and restore
