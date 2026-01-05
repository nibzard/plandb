//! Relationship Cartridge Storage
//!
//! Stores relationships between entities extracted from database commits.
//! Relationships enable semantic navigation and dependency tracking.

use crate::error::{Error as DbError, IoError, Result};
use crate::types::TransactionId;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::sync::RwLock;

/// Relationship type enumeration
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, Hash)]
pub enum RelationshipType {
    /// File contains function
    Contains,
    /// Function uses topic
    Uses,
    /// Person modifies file
    Modifies,
    /// Semantic relationship
    RelatedTo,
    /// Function implements topic
    Implements,
    /// Function calls function
    Calls,
    /// Entity depends on entity
    DependsOn,
}

impl RelationshipType {
    /// Convert relationship type to string
    pub fn as_str(&self) -> &str {
        match self {
            RelationshipType::Contains => "contains",
            RelationshipType::Uses => "uses",
            RelationshipType::Modifies => "modifies",
            RelationshipType::RelatedTo => "related_to",
            RelationshipType::Implements => "implements",
            RelationshipType::Calls => "calls",
            RelationshipType::DependsOn => "depends_on",
        }
    }

    /// Parse relationship type from string
    pub fn from_str(s: &str) -> Option<Self> {
        match s {
            "contains" => Some(RelationshipType::Contains),
            "uses" => Some(RelationshipType::Uses),
            "modifies" => Some(RelationshipType::Modifies),
            "related_to" => Some(RelationshipType::RelatedTo),
            "implements" => Some(RelationshipType::Implements),
            "calls" => Some(RelationshipType::Calls),
            "depends_on" => Some(RelationshipType::DependsOn),
            _ => None,
        }
    }
}

/// Relationship between two entities
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Relationship {
    /// Unique relationship ID
    pub id: String,
    /// Source entity ID
    pub from_entity: String,
    /// Target entity ID
    pub to_entity: String,
    /// Relationship type
    pub rel_type: RelationshipType,
    /// Relationship strength (0.0-1.0)
    pub weight: f32,
    /// Source commit ID
    pub commit_id: TransactionId,
    /// Confidence score (0.0-1.0)
    pub confidence: f32,
}

impl Relationship {
    /// Create a new relationship
    pub fn new(
        id: String,
        from_entity: String,
        to_entity: String,
        rel_type: RelationshipType,
        weight: f32,
        commit_id: TransactionId,
        confidence: f32,
    ) -> Self {
        Self {
            id,
            from_entity,
            to_entity,
            rel_type,
            weight,
            commit_id,
            confidence,
        }
    }

    /// Generate relationship ID from components
    pub fn generate_id(
        from_entity: &str,
        to_entity: &str,
        rel_type: &RelationshipType,
    ) -> String {
        format!("{}:{}:{}", from_entity, rel_type.as_str(), to_entity)
    }
}

/// Relationship cartridge for storing and querying relationships
#[derive(Debug)]
pub struct RelationshipCartridge {
    /// All relationships indexed by ID
    relationships: RwLock<HashMap<String, Relationship>>,
    /// Relationships indexed by from entity
    from_index: RwLock<HashMap<String, Vec<String>>>,
    /// Relationships indexed by to entity
    to_index: RwLock<HashMap<String, Vec<String>>>,
    /// Relationships indexed by commit ID
    by_commit: RwLock<HashMap<TransactionId, Vec<String>>>,
    /// Relationships indexed by type
    by_type: RwLock<HashMap<RelationshipType, Vec<String>>>,
}

impl Default for RelationshipCartridge {
    fn default() -> Self {
        Self::new()
    }
}

impl RelationshipCartridge {
    /// Create a new relationship cartridge
    pub fn new() -> Self {
        Self {
            relationships: RwLock::new(HashMap::new()),
            from_index: RwLock::new(HashMap::new()),
            to_index: RwLock::new(HashMap::new()),
            by_commit: RwLock::new(HashMap::new()),
            by_type: RwLock::new(HashMap::new()),
        }
    }

    /// Insert a relationship into the cartridge
    pub fn insert(&self, relationship: Relationship) -> Result<()> {
        let from_entity = relationship.from_entity.clone();
        let to_entity = relationship.to_entity.clone();
        let rel_type = relationship.rel_type.clone();
        let id = relationship.id.clone();
        let commit_id = relationship.commit_id;

        // Insert main relationship
        {
            let mut relationships = self.relationships.write()
                .map_err(|e| DbError::Io(IoError::InternalError(format!("Failed to acquire write lock: {}", e))))?;
            relationships.insert(id.clone(), relationship);
        }

        // Update from index
        {
            let mut from_index = self.from_index.write()
                .map_err(|e| DbError::Io(IoError::InternalError(format!("Failed to acquire write lock: {}", e))))?;
            from_index.entry(from_entity).or_insert_with(Vec::new).push(id.clone());
        }

        // Update to index
        {
            let mut to_index = self.to_index.write()
                .map_err(|e| DbError::Io(IoError::InternalError(format!("Failed to acquire write lock: {}", e))))?;
            to_index.entry(to_entity).or_insert_with(Vec::new).push(id.clone());
        }

        // Update type index
        {
            let mut by_type = self.by_type.write()
                .map_err(|e| DbError::Io(IoError::InternalError(format!("Failed to acquire write lock: {}", e))))?;
            by_type.entry(rel_type).or_insert_with(Vec::new).push(id.clone());
        }

        // Update commit index
        {
            let mut by_commit = self.by_commit.write()
                .map_err(|e| DbError::Io(IoError::InternalError(format!("Failed to acquire write lock: {}", e))))?;
            by_commit.entry(commit_id).or_insert_with(Vec::new).push(id);
        }

        Ok(())
    }

    /// Get relationship by ID
    pub fn get(&self, id: &str) -> Result<Option<Relationship>> {
        let relationships = self.relationships.read()
            .map_err(|e| DbError::Io(IoError::InternalError(format!("Failed to acquire read lock: {}", e))))?;
        Ok(relationships.get(id).cloned())
    }

    /// Get all relationships from an entity
    pub fn get_from_entity(&self, from_entity: &str) -> Result<Vec<Relationship>> {
        let from_index = self.from_index.read()
            .map_err(|e| DbError::Io(IoError::InternalError(format!("Failed to acquire read lock: {}", e))))?;

        let ids = from_index.get(from_entity).cloned().unwrap_or_default();

        let relationships = self.relationships.read()
            .map_err(|e| DbError::Io(IoError::InternalError(format!("Failed to acquire read lock: {}", e))))?;

        let result = ids.iter()
            .filter_map(|id| relationships.get(id).cloned())
            .collect();

        Ok(result)
    }

    /// Get all relationships to an entity
    pub fn get_to_entity(&self, to_entity: &str) -> Result<Vec<Relationship>> {
        let to_index = self.to_index.read()
            .map_err(|e| DbError::Io(IoError::InternalError(format!("Failed to acquire read lock: {}", e))))?;

        let ids = to_index.get(to_entity).cloned().unwrap_or_default();

        let relationships = self.relationships.read()
            .map_err(|e| DbError::Io(IoError::InternalError(format!("Failed to acquire read lock: {}", e))))?;

        let result = ids.iter()
            .filter_map(|id| relationships.get(id).cloned())
            .collect();

        Ok(result)
    }

    /// Get all relationships from an entity (alias for get_from_entity)
    pub fn get_from(&self, from_entity: &str) -> Result<Vec<Relationship>> {
        self.get_from_entity(from_entity)
    }

    /// Get all relationships to an entity (alias for get_to_entity)
    pub fn get_to(&self, to_entity: &str) -> Result<Vec<Relationship>> {
        self.get_to_entity(to_entity)
    }

    /// Get all relationships of a specific type
    pub fn get_by_type(&self, rel_type: RelationshipType) -> Result<Vec<Relationship>> {
        let by_type = self.by_type.read()
            .map_err(|e| DbError::Io(IoError::InternalError(format!("Failed to acquire read lock: {}", e))))?;

        let ids = by_type.get(&rel_type).cloned().unwrap_or_default();

        let relationships = self.relationships.read()
            .map_err(|e| DbError::Io(IoError::InternalError(format!("Failed to acquire read lock: {}", e))))?;

        let result = ids.iter()
            .filter_map(|id| relationships.get(id).cloned())
            .collect();

        Ok(result)
    }

    /// Get all relationships from a specific commit
    pub fn get_by_commit(&self, commit_id: TransactionId) -> Result<Vec<Relationship>> {
        let by_commit = self.by_commit.read()
            .map_err(|e| DbError::Io(IoError::InternalError(format!("Failed to acquire read lock: {}", e))))?;

        let ids = by_commit.get(&commit_id).cloned().unwrap_or_default();

        let relationships = self.relationships.read()
            .map_err(|e| DbError::Io(IoError::InternalError(format!("Failed to acquire read lock: {}", e))))?;

        let result = ids.iter()
            .filter_map(|id| relationships.get(id).cloned())
            .collect();

        Ok(result)
    }

    /// Get all relationships
    pub fn get_all(&self) -> Result<Vec<Relationship>> {
        let relationships = self.relationships.read()
            .map_err(|e| DbError::Io(IoError::InternalError(format!("Failed to acquire read lock: {}", e))))?;

        Ok(relationships.values().cloned().collect())
    }

    /// Count total relationships
    pub fn count(&self) -> Result<usize> {
        let relationships = self.relationships.read()
            .map_err(|e| DbError::Io(IoError::InternalError(format!("Failed to acquire read lock: {}", e))))?;
        Ok(relationships.len())
    }

    /// Clear all relationships
    pub fn clear(&self) -> Result<()> {
        {
            let mut relationships = self.relationships.write()
                .map_err(|e| DbError::Io(IoError::InternalError(format!("Failed to acquire write lock: {}", e))))?;
            relationships.clear();
        }
        {
            let mut from_index = self.from_index.write()
                .map_err(|e| DbError::Io(IoError::InternalError(format!("Failed to acquire write lock: {}", e))))?;
            from_index.clear();
        }
        {
            let mut to_index = self.to_index.write()
                .map_err(|e| DbError::Io(IoError::InternalError(format!("Failed to acquire write lock: {}", e))))?;
            to_index.clear();
        }
        {
            let mut by_type = self.by_type.write()
                .map_err(|e| DbError::Io(IoError::InternalError(format!("Failed to acquire write lock: {}", e))))?;
            by_type.clear();
        }
        {
            let mut by_commit = self.by_commit.write()
                .map_err(|e| DbError::Io(IoError::InternalError(format!("Failed to acquire write lock: {}", e))))?;
            by_commit.clear();
        }

        Ok(())
    }

    /// Find bidirectional relationships (both from and to)
    pub fn get_bidirectional(&self, entity: &str) -> Result<Vec<Relationship>> {
        let mut result = Vec::new();

        // Get outgoing relationships
        result.extend(self.get_from_entity(entity)?);

        // Get incoming relationships
        result.extend(self.get_to_entity(entity)?);

        Ok(result)
    }

    /// Find path between two entities using BFS
    pub fn find_path(&self, from: &str, to: &str, max_depth: usize) -> Result<Vec<String>> {
        use std::collections::VecDeque;

        if from == to {
            return Ok(vec![from.to_string()]);
        }

        let mut visited = HashMap::new();
        let mut queue = VecDeque::new();
        queue.push_back((from.to_string(), 0));

        while let Some((current, depth)) = queue.pop_front() {
            if depth >= max_depth {
                continue;
            }

            let relationships = self.get_from_entity(&current)?;

            for rel in relationships {
                let next = &rel.to_entity;

                if !visited.contains_key(next) {
                    visited.insert(next.clone(), current.clone());

                    if next == to {
                        // Reconstruct path
                        let mut path = vec![to.to_string()];
                        let mut current = to;
                        while current != from {
                            if let Some(prev) = visited.get(current) {
                                path.push(prev.clone());
                                current = prev;
                            } else {
                                break;
                            }
                        }
                        path.reverse();
                        return Ok(path);
                    }

                    queue.push_back((next.clone(), depth + 1));
                }
            }
        }

        Err(DbError::Io(IoError::InternalError(format!("No path found between {} and {}", from, to))))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::types::TransactionId;

    #[test]
    fn test_relationship_type_conversion() {
        assert_eq!(RelationshipType::Contains.as_str(), "contains");
        assert_eq!(RelationshipType::from_str("contains"), Some(RelationshipType::Contains));
        assert_eq!(RelationshipType::from_str("invalid"), None);
    }

    #[test]
    fn test_relationship_cartridge_insert() {
        let cartridge = RelationshipCartridge::new();
        let relationship = Relationship::new(
            "rel-1".to_string(),
            "file-1".to_string(),
            "function-1".to_string(),
            RelationshipType::Contains,
            1.0,
            TransactionId::new(1),
            0.9,
        );

        cartridge.insert(relationship).unwrap();
        assert_eq!(cartridge.count().unwrap(), 1);
    }

    #[test]
    fn test_relationship_cartridge_get() {
        let cartridge = RelationshipCartridge::new();
        let relationship = Relationship::new(
            "rel-1".to_string(),
            "file-1".to_string(),
            "function-1".to_string(),
            RelationshipType::Contains,
            1.0,
            TransactionId::new(1),
            0.9,
        );

        cartridge.insert(relationship.clone()).unwrap();

        // Get by ID
        let retrieved = cartridge.get("rel-1").unwrap().unwrap();
        assert_eq!(retrieved.id, "rel-1");
        assert_eq!(retrieved.from_entity, "file-1");
        assert_eq!(retrieved.to_entity, "function-1");

        // Get from entity
        let from_entity = cartridge.get_from_entity("file-1").unwrap();
        assert_eq!(from_entity.len(), 1);

        // Get to entity
        let to_entity = cartridge.get_to_entity("function-1").unwrap();
        assert_eq!(to_entity.len(), 1);

        // Get by type
        let by_type = cartridge.get_by_type(RelationshipType::Contains).unwrap();
        assert_eq!(by_type.len(), 1);
    }

    #[test]
    fn test_relationship_generate_id() {
        let id = Relationship::generate_id(
            "file-1",
            "function-1",
            &RelationshipType::Contains,
        );
        assert_eq!(id, "file-1:contains:function-1");
    }

    #[test]
    fn test_find_path() {
        let cartridge = RelationshipCartridge::new();

        // Create a chain: A -> B -> C -> D
        cartridge.insert(Relationship::new(
            "rel-1".to_string(),
            "A".to_string(),
            "B".to_string(),
            RelationshipType::Calls,
            1.0,
            TransactionId::new(1),
            0.9,
        )).unwrap();

        cartridge.insert(Relationship::new(
            "rel-2".to_string(),
            "B".to_string(),
            "C".to_string(),
            RelationshipType::Calls,
            1.0,
            TransactionId::new(1),
            0.9,
        )).unwrap();

        cartridge.insert(Relationship::new(
            "rel-3".to_string(),
            "C".to_string(),
            "D".to_string(),
            RelationshipType::Calls,
            1.0,
            TransactionId::new(1),
            0.9,
        )).unwrap();

        let path = cartridge.find_path("A", "D", 10).unwrap();
        assert_eq!(path, vec!["A", "B", "C", "D"]);
    }
}
