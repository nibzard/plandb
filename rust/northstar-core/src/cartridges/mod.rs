//! Structured Memory Cartridges
//!
//! Cartridges provide persistent, time-travel enabled storage for structured
//! data extracted from database commits. Each cartridge type specializes in
//! storing different kinds of entities and relationships.

pub mod entity;
pub mod topic;
pub mod relationship;

// Re-exports for convenience
pub use entity::{Entity, EntityCartridge, EntityType, FileEntity, FunctionEntity, PersonEntity, ConfigEntity};
pub use topic::{Topic, TopicCartridge, TopicCategory};
pub use relationship::{Relationship, RelationshipCartridge, RelationshipType};
