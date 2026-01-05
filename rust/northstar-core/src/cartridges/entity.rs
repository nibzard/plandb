//! Entity Cartridge Storage
//!
//! Stores extracted entities from database commits with time-travel support.
//! Entities include files, functions, people, topics, and configurations.

use crate::error::{Error as DbError, IoError, Result};
use crate::types::TransactionId;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::sync::RwLock;

/// Entity type enumeration
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq, Hash)]
pub enum EntityType {
    /// Source code file
    File,
    /// Function or method
    Function,
    /// Person (developer, reviewer, etc.)
    Person,
    /// Topic or category
    Topic,
    /// Configuration key-value
    Config,
}

impl EntityType {
    /// Convert entity type to string key prefix
    pub fn as_str(&self) -> &str {
        match self {
            EntityType::File => "file",
            EntityType::Function => "function",
            EntityType::Person => "person",
            EntityType::Topic => "topic",
            EntityType::Config => "config",
        }
    }

    /// Parse entity type from string
    pub fn from_str(s: &str) -> Option<Self> {
        match s {
            "file" => Some(EntityType::File),
            "function" => Some(EntityType::Function),
            "person" => Some(EntityType::Person),
            "topic" => Some(EntityType::Topic),
            "config" => Some(EntityType::Config),
            _ => None,
        }
    }
}

/// Base entity structure
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Entity {
    /// Unique entity ID
    pub id: String,
    /// Entity type
    pub entity_type: EntityType,
    /// Entity name
    pub name: String,
    /// Source commit ID
    pub commit_id: TransactionId,
    /// Confidence score (0.0-1.0)
    pub confidence: f32,
    /// Additional metadata
    pub metadata: HashMap<String, String>,
}

impl Entity {
    /// Create a new entity
    pub fn new(
        id: String,
        entity_type: EntityType,
        name: String,
        commit_id: TransactionId,
        confidence: f32,
    ) -> Self {
        Self {
            id,
            entity_type,
            name,
            commit_id,
            confidence,
            metadata: HashMap::new(),
        }
    }

    /// Add metadata key-value pair
    pub fn with_metadata(mut self, key: String, value: String) -> Self {
        self.metadata.insert(key, value);
        self
    }

    /// Get entity ID
    pub fn id(&self) -> &str {
        &self.id
    }

    /// Get entity name
    pub fn name(&self) -> &str {
        &self.name
    }

    /// Get entity confidence
    pub fn confidence(&self) -> f32 {
        self.confidence
    }

    /// Get commit ID
    pub fn commit_id(&self) -> Option<TransactionId> {
        Some(self.commit_id)
    }
}

/// File entity with specific attributes
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FileEntity {
    /// Base entity data
    pub entity: Entity,
    /// File path
    pub path: String,
    /// Programming language
    pub language: String,
    /// File size in bytes
    pub size: u64,
}

impl FileEntity {
    /// Create a new file entity
    pub fn new(
        id: String,
        path: String,
        language: String,
        size: u64,
        commit_id: TransactionId,
        confidence: f32,
    ) -> Self {
        let name = path.rsplit('/').next().unwrap_or(&path).to_string();
        let entity = Entity::new(
            id,
            EntityType::File,
            name,
            commit_id,
            confidence,
        );

        Self {
            entity,
            path,
            language,
            size,
        }
    }
}

/// Function entity with specific attributes
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FunctionEntity {
    /// Base entity data
    pub entity: Entity,
    /// Function signature
    pub signature: String,
    /// File path containing this function
    pub file_path: String,
    /// Line number start
    pub line_start: u32,
    /// Line number end
    pub line_end: u32,
}

impl FunctionEntity {
    /// Create a new function entity
    pub fn new(
        id: String,
        name: String,
        signature: String,
        file_path: String,
        line_start: u32,
        line_end: u32,
        commit_id: TransactionId,
        confidence: f32,
    ) -> Self {
        let entity = Entity::new(
            id,
            EntityType::Function,
            name,
            commit_id,
            confidence,
        );

        Self {
            entity,
            signature,
            file_path,
            line_start,
            line_end,
        }
    }
}

/// Person entity with specific attributes
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PersonEntity {
    /// Base entity data
    pub entity: Entity,
    /// Person role (developer, reviewer, etc.)
    pub role: String,
    /// Contact information (optional)
    pub contact: Option<String>,
}

impl PersonEntity {
    /// Create a new person entity
    pub fn new(
        id: String,
        name: String,
        role: String,
        contact: Option<String>,
        commit_id: TransactionId,
        confidence: f32,
    ) -> Self {
        let entity = Entity::new(
            id,
            EntityType::Person,
            name,
            commit_id,
            confidence,
        );

        Self {
            entity,
            role,
            contact,
        }
    }
}

/// Config entity with specific attributes
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ConfigEntity {
    /// Base entity data
    pub entity: Entity,
    /// Configuration key
    pub key: String,
    /// Configuration value
    pub value: String,
    /// Source (file or environment)
    pub source: String,
}

impl ConfigEntity {
    /// Create a new config entity
    pub fn new(
        id: String,
        key: String,
        value: String,
        source: String,
        commit_id: TransactionId,
        confidence: f32,
    ) -> Self {
        let entity = Entity::new(
            id,
            EntityType::Config,
            key.clone(),
            commit_id,
            confidence,
        );

        Self {
            entity,
            key,
            value,
            source,
        }
    }
}

/// Unified entity enum for query system
#[derive(Debug, Clone)]
pub enum UnifiedEntity {
    File(FileEntity),
    Function(FunctionEntity),
    Person(PersonEntity),
    Config(ConfigEntity),
    Base(Entity),
}

impl UnifiedEntity {
    /// Get entity ID
    pub fn id(&self) -> &str {
        match self {
            UnifiedEntity::File(f) => &f.entity.id,
            UnifiedEntity::Function(f) => &f.entity.id,
            UnifiedEntity::Person(p) => &p.entity.id,
            UnifiedEntity::Config(c) => &c.entity.id,
            UnifiedEntity::Base(e) => &e.id,
        }
    }

    /// Get entity name
    pub fn name(&self) -> &str {
        match self {
            UnifiedEntity::File(f) => &f.entity.name,
            UnifiedEntity::Function(f) => &f.entity.name,
            UnifiedEntity::Person(p) => &p.entity.name,
            UnifiedEntity::Config(c) => &c.entity.name,
            UnifiedEntity::Base(e) => &e.name,
        }
    }

    /// Get entity confidence
    pub fn confidence(&self) -> f32 {
        match self {
            UnifiedEntity::File(f) => f.entity.confidence,
            UnifiedEntity::Function(f) => f.entity.confidence,
            UnifiedEntity::Person(p) => p.entity.confidence,
            UnifiedEntity::Config(c) => c.entity.confidence,
            UnifiedEntity::Base(e) => e.confidence,
        }
    }

    /// Get commit ID
    pub fn commit_id(&self) -> Option<TransactionId> {
        match self {
            UnifiedEntity::File(f) => Some(f.entity.commit_id),
            UnifiedEntity::Function(f) => Some(f.entity.commit_id),
            UnifiedEntity::Person(p) => Some(p.entity.commit_id),
            UnifiedEntity::Config(c) => Some(c.entity.commit_id),
            UnifiedEntity::Base(e) => Some(e.commit_id),
        }
    }
}

// For backwards compatibility in the query system, we'll use Entity as an alias
pub type EntityForQuery = UnifiedEntity;

/// Entity cartridge for storing and querying entities
#[derive(Debug)]
pub struct EntityCartridge {
    /// All entities indexed by ID
    entities: RwLock<HashMap<String, Entity>>,
    /// Entities indexed by type
    by_type: RwLock<HashMap<EntityType, Vec<String>>>,
    /// Entities indexed by name
    by_name: RwLock<HashMap<String, String>>,
    /// Entities indexed by commit ID
    by_commit: RwLock<HashMap<TransactionId, Vec<String>>>,
}

impl Default for EntityCartridge {
    fn default() -> Self {
        Self::new()
    }
}

impl EntityCartridge {
    /// Create a new entity cartridge
    pub fn new() -> Self {
        Self {
            entities: RwLock::new(HashMap::new()),
            by_type: RwLock::new(HashMap::new()),
            by_name: RwLock::new(HashMap::new()),
            by_commit: RwLock::new(HashMap::new()),
        }
    }

    /// Insert an entity into the cartridge
    pub fn insert(&self, entity: Entity) -> Result<()> {
        let entity_type = entity.entity_type.clone();
        let id = entity.id.clone();
        let name = entity.name.clone();
        let commit_id = entity.commit_id;

        // Insert main entity
        {
            let mut entities = self.entities.write()
                .map_err(|e| DbError::Io(IoError::InternalError(format!("Failed to acquire write lock: {}", e))))?;
            entities.insert(id.clone(), entity);
        }

        // Update type index
        {
            let mut by_type = self.by_type.write()
                .map_err(|e| DbError::Io(IoError::InternalError(format!("Failed to acquire write lock: {}", e))))?;
            by_type.entry(entity_type).or_insert_with(Vec::new).push(id.clone());
        }

        // Update name index
        {
            let mut by_name = self.by_name.write()
                .map_err(|e| DbError::Io(IoError::InternalError(format!("Failed to acquire write lock: {}", e))))?;
            by_name.insert(name, id.clone());
        }

        // Update commit index
        {
            let mut by_commit = self.by_commit.write()
                .map_err(|e| DbError::Io(IoError::InternalError(format!("Failed to acquire write lock: {}", e))))?;
            by_commit.entry(commit_id).or_insert_with(Vec::new).push(id);
        }

        Ok(())
    }

    /// Get entity by ID
    pub fn get(&self, id: &str) -> Result<Option<Entity>> {
        let entities = self.entities.read()
            .map_err(|e| DbError::Io(IoError::InternalError(format!("Failed to acquire read lock: {}", e))))?;
        Ok(entities.get(id).cloned())
    }

    /// Get all entities of a specific type
    pub fn get_by_type(&self, entity_type: EntityType) -> Result<Vec<Entity>> {
        let by_type = self.by_type.read()
            .map_err(|e| DbError::Io(IoError::InternalError(format!("Failed to acquire read lock: {}", e))))?;

        let ids = by_type.get(&entity_type).cloned().unwrap_or_default();

        let entities = self.entities.read()
            .map_err(|e| DbError::Io(IoError::InternalError(format!("Failed to acquire read lock: {}", e))))?;

        let result = ids.iter()
            .filter_map(|id| entities.get(id).cloned())
            .collect();

        Ok(result)
    }

    /// Get entity by name
    pub fn get_by_name(&self, name: &str) -> Result<Option<Entity>> {
        let by_name = self.by_name.read()
            .map_err(|e| DbError::Io(IoError::InternalError(format!("Failed to acquire read lock: {}", e))))?;

        if let Some(id) = by_name.get(name) {
            let entities = self.entities.read()
                .map_err(|e| DbError::Io(IoError::InternalError(format!("Failed to acquire read lock: {}", e))))?;
            Ok(entities.get(id).cloned())
        } else {
            Ok(None)
        }
    }

    /// Get all entities from a specific commit
    pub fn get_by_commit(&self, commit_id: TransactionId) -> Result<Vec<Entity>> {
        let by_commit = self.by_commit.read()
            .map_err(|e| DbError::Io(IoError::InternalError(format!("Failed to acquire read lock: {}", e))))?;

        let ids = by_commit.get(&commit_id).cloned().unwrap_or_default();

        let entities = self.entities.read()
            .map_err(|e| DbError::Io(IoError::InternalError(format!("Failed to acquire read lock: {}", e))))?;

        let result = ids.iter()
            .filter_map(|id| entities.get(id).cloned())
            .collect();

        Ok(result)
    }

    /// Get all entities
    pub fn get_all(&self) -> Result<Vec<Entity>> {
        let entities = self.entities.read()
            .map_err(|e| DbError::Io(IoError::InternalError(format!("Failed to acquire read lock: {}", e))))?;

        Ok(entities.values().cloned().collect())
    }

    /// Count total entities
    pub fn count(&self) -> Result<usize> {
        let entities = self.entities.read()
            .map_err(|e| DbError::Io(IoError::InternalError(format!("Failed to acquire read lock: {}", e))))?;
        Ok(entities.len())
    }

    /// Clear all entities
    pub fn clear(&self) -> Result<()> {
        {
            let mut entities = self.entities.write()
                .map_err(|e| DbError::Io(IoError::InternalError(format!("Failed to acquire write lock: {}", e))))?;
            entities.clear();
        }
        {
            let mut by_type = self.by_type.write()
                .map_err(|e| DbError::Io(IoError::InternalError(format!("Failed to acquire write lock: {}", e))))?;
            by_type.clear();
        }
        {
            let mut by_name = self.by_name.write()
                .map_err(|e| DbError::Io(IoError::InternalError(format!("Failed to acquire write lock: {}", e))))?;
            by_name.clear();
        }
        {
            let mut by_commit = self.by_commit.write()
                .map_err(|e| DbError::Io(IoError::InternalError(format!("Failed to acquire write lock: {}", e))))?;
            by_commit.clear();
        }

        Ok(())
    }

    /// Get entity by ID (alias for get)
    pub fn get_by_id(&self, id: &str) -> Result<Option<Entity>> {
        self.get(id)
    }

    /// Get all files
    pub fn get_all_files(&self) -> Result<Vec<Entity>> {
        self.get_by_type(EntityType::File)
    }

    /// Get all functions
    pub fn get_all_functions(&self) -> Result<Vec<Entity>> {
        self.get_by_type(EntityType::Function)
    }

    /// Get all persons
    pub fn get_all_persons(&self) -> Result<Vec<Entity>> {
        self.get_by_type(EntityType::Person)
    }

    /// Get all configs
    pub fn get_all_configs(&self) -> Result<Vec<Entity>> {
        self.get_by_type(EntityType::Config)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::types::TransactionId;

    #[test]
    fn test_entity_type_conversion() {
        assert_eq!(EntityType::File.as_str(), "file");
        assert_eq!(EntityType::from_str("file"), Some(EntityType::File));
        assert_eq!(EntityType::from_str("invalid"), None);
    }

    #[test]
    fn test_entity_cartridge_insert() {
        let cartridge = EntityCartridge::new();
        let entity = Entity::new(
            "test-1".to_string(),
            EntityType::File,
            "test.rs".to_string(),
            TransactionId::new(1),
            0.9,
        );

        cartridge.insert(entity).unwrap();
        assert_eq!(cartridge.count().unwrap(), 1);
    }

    #[test]
    fn test_entity_cartridge_get() {
        let cartridge = EntityCartridge::new();
        let entity = Entity::new(
            "test-1".to_string(),
            EntityType::File,
            "test.rs".to_string(),
            TransactionId::new(1),
            0.9,
        );

        cartridge.insert(entity.clone()).unwrap();

        // Get by ID
        let retrieved = cartridge.get("test-1").unwrap().unwrap();
        assert_eq!(retrieved.id, "test-1");
        assert_eq!(retrieved.name, "test.rs");

        // Get by name
        let by_name = cartridge.get_by_name("test.rs").unwrap().unwrap();
        assert_eq!(by_name.id, "test-1");

        // Get by type
        let by_type = cartridge.get_by_type(EntityType::File).unwrap();
        assert_eq!(by_type.len(), 1);

        // Get by commit
        let by_commit = cartridge.get_by_commit(TransactionId::new(1)).unwrap();
        assert_eq!(by_commit.len(), 1);
    }
}
