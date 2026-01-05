//! Query types and intents

use crate::cartridges::{Entity, EntityType, Relationship, RelationshipType, Topic};
use crate::types::Lsn;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;

/// Intent of a natural language query
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub enum QueryIntent {
    /// Direct key lookup: "Get file X"
    PointLookup,

    /// Range query: "Show all commits between X and Y"
    RangeScan,

    /// Semantic search: "Find storage-related work"
    SemanticSearch,

    /// Aggregation: "Count commits by nikos"
    Aggregation {
        agg_type: AggregationType,
        field: String,
    },

    /// Relationship traversal: "What files does person X modify?"
    RelationshipTraversal {
        rel_type: RelationshipType,
        direction: TraversalDirection,
    },

    /// Time-travel query: "Show state at LSN X"
    TimeTravel {
        lsn: Lsn,
    },

    /// Complex query with multiple operations
    Complex {
        operations: Vec<QueryOperation>,
    },
}

/// Aggregation type for aggregate queries
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum AggregationType {
    Count,
    Sum,
    Average,
    Min,
    Max,
}

/// Traversal direction for relationship queries
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum TraversalDirection {
    /// entity → related entities
    Outgoing,

    /// related entities → entity
    Incoming,

    /// bidirectional traversal
    Both,
}

/// Query plan for execution
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct QueryPlan {
    /// Query intent
    pub intent: QueryIntent,

    /// Operations to execute
    pub operations: Vec<QueryOperation>,

    /// Entity links from query text to entity IDs
    pub entity_links: HashMap<String, String>,

    /// Estimated execution cost
    pub estimated_cost: f32,

    /// Execution hint
    pub execution_hint: ExecutionHint,
}

/// Query operation
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub enum QueryOperation {
    /// Point lookup: get(key)
    PointLookup { key: Vec<u8> },

    /// Range scan: scan(start, end)
    RangeScan { start: Vec<u8>, end: Vec<u8> },

    /// Cartridge lookup
    EntityLookup {
        cartridge_type: CartridgeType,
        lookup_type: LookupType,
        key: String,
    },

    /// Relationship traversal
    RelationshipTraversal {
        from_entity: String,
        rel_type: RelationshipType,
        direction: TraversalDirection,
        max_depth: usize,
    },

    /// Filter operation
    Filter {
        field: String,
        operator: FilterOperator,
        value: serde_json::Value,
    },

    /// Aggregation operation
    Aggregate {
        agg_type: AggregationType,
        field: String,
        group_by: Option<String>,
    },

    /// Sort operation
    Sort {
        field: String,
        ascending: bool,
    },

    /// Limit operation
    Limit { count: usize },
}

/// Cartridge type for lookups
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum CartridgeType {
    Entity,
    Topic,
    Relationship,
}

/// Lookup type for cartridge queries
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum LookupType {
    ById,
    ByType,
    ByName,
    ByCommit,
    ByCategory,
    ByKeyword,
}

/// Filter operator
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub enum FilterOperator {
    Equals,
    NotEquals,
    GreaterThan,
    LessThan,
    Contains,
    Matches, // Regex
}

/// Execution hint for query executor
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub enum ExecutionHint {
    /// Use index if available
    UseIndex { index_name: String },

    /// Prefer cache
    UseCache,

    /// Parallelize independent operations
    Parallelize,

    /// Specific execution order
    Order(Vec<usize>),
}

/// Extracted entity from query
#[derive(Debug, Clone)]
pub struct ExtractedEntity {
    /// Entity text as it appears in query
    pub text: String,

    /// Entity type
    pub entity_type: EntityType,

    /// Confidence score 0-1
    pub confidence: f32,

    /// Position in query (start, end)
    pub position: (usize, usize),
}

/// Entity linking result
#[derive(Debug, Clone)]
pub struct LinkResult {
    /// Linked entity ID
    pub entity_id: String,

    /// Link confidence
    pub confidence: f32,

    /// Match type
    pub match_type: MatchType,
}

/// Match type for entity linking
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MatchType {
    /// Direct name match
    Exact,

    /// Edit distance match
    Fuzzy,

    /// Topic keyword match
    Semantic,

    /// Partial string match
    Partial,
}

/// Query explanation
#[derive(Debug, Clone)]
pub struct Explanation {
    /// Original natural language query
    pub original_query: String,

    /// Query intent
    pub intent: String,

    /// Operations
    pub operations: Vec<String>,

    /// Entity links
    pub entity_links: HashMap<String, String>,

    /// Estimated cost
    pub estimated_cost: f32,

    /// Execution strategy
    pub execution_strategy: String,

    /// Optimization notes
    pub optimization_notes: Vec<String>,
}

/// Ranked entity with relevance score
#[derive(Debug, Clone)]
pub struct RankedEntity {
    /// Entity
    pub entity: Entity,

    /// Relevance score 0-1
    pub relevance_score: f32,

    /// Reason for ranking
    pub rank_reason: String,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_query_intent_serialization() {
        let intent = QueryIntent::PointLookup;
        let json = serde_json::to_string(&intent).unwrap();
        let deserialized: QueryIntent = serde_json::from_str(&json).unwrap();
        assert_eq!(intent, deserialized);
    }

    #[test]
    fn test_aggregation_type() {
        let agg = AggregationType::Count;
        assert_eq!(format!("{:?}", agg), "Count");
    }

    #[test]
    fn test_execution_hint() {
        let hint = ExecutionHint::UseIndex {
            index_name: "test".to_string(),
        };
        assert_eq!(format!("{:?}", hint), "UseIndex { index_name: \"test\" }");
    }
}
