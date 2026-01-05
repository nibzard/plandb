//! Topic Cartridge Storage
//!
//! Stores topics and categories extracted from database commits.
//! Topics provide semantic grouping and categorization of entities.

use crate::error::{Error as DbError, IoError, Result};
use crate::types::TransactionId;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::sync::RwLock;

/// Topic category enumeration
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, Hash)]
pub enum TopicCategory {
    /// New functionality
    Feature,
    /// Issue resolution
    Bugfix,
    /// Code restructuring
    Refactor,
    /// Build, CI, deployment
    Infrastructure,
    /// Documentation and comments
    Documentation,
    /// Performance optimizations
    Performance,
    /// Tests and benchmarks
    Testing,
    /// Custom category
    Custom(String),
}

impl TopicCategory {
    /// Convert category to string
    pub fn as_str(&self) -> &str {
        match self {
            TopicCategory::Feature => "feature",
            TopicCategory::Bugfix => "bugfix",
            TopicCategory::Refactor => "refactor",
            TopicCategory::Infrastructure => "infrastructure",
            TopicCategory::Documentation => "documentation",
            TopicCategory::Performance => "performance",
            TopicCategory::Testing => "testing",
            TopicCategory::Custom(s) => s,
        }
    }

    /// Parse category from string
    pub fn from_str(s: &str) -> Self {
        match s {
            "feature" => TopicCategory::Feature,
            "bugfix" => TopicCategory::Bugfix,
            "refactor" => TopicCategory::Refactor,
            "infrastructure" => TopicCategory::Infrastructure,
            "documentation" => TopicCategory::Documentation,
            "performance" => TopicCategory::Performance,
            "testing" => TopicCategory::Testing,
            custom => TopicCategory::Custom(custom.to_string()),
        }
    }
}

/// Topic entity
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Topic {
    /// Unique topic ID
    pub id: String,
    /// Topic name
    pub name: String,
    /// Topic category
    pub category: TopicCategory,
    /// Associated keywords
    pub keywords: Vec<String>,
    /// Optional description
    pub description: Option<String>,
    /// Source commit ID
    pub commit_id: TransactionId,
    /// Confidence score (0.0-1.0)
    pub confidence: f32,
    /// Associated entity IDs
    pub entity_ids: Vec<String>,
}

impl Topic {
    /// Create a new topic
    pub fn new(
        id: String,
        name: String,
        category: TopicCategory,
        keywords: Vec<String>,
        commit_id: TransactionId,
        confidence: f32,
    ) -> Self {
        Self {
            id,
            name,
            category,
            keywords,
            description: None,
            commit_id,
            confidence,
            entity_ids: Vec::new(),
        }
    }

    /// Set description
    pub fn with_description(mut self, description: String) -> Self {
        self.description = Some(description);
        self
    }

    /// Add entity ID to topic
    pub fn with_entity(mut self, entity_id: String) -> Self {
        self.entity_ids.push(entity_id);
        self
    }

    /// Check if topic matches a keyword
    pub fn matches_keyword(&self, keyword: &str) -> bool {
        self.keywords.iter()
            .any(|k| k.eq_ignore_ascii_case(keyword))
    }
}

/// Topic cartridge for storing and querying topics
#[derive(Debug)]
pub struct TopicCartridge {
    /// All topics indexed by ID
    topics: RwLock<HashMap<String, Topic>>,
    /// Topics indexed by category
    by_category: RwLock<HashMap<String, Vec<String>>>,
    /// Topics indexed by keyword
    by_keyword: RwLock<HashMap<String, Vec<String>>>,
    /// Topics indexed by commit ID
    by_commit: RwLock<HashMap<TransactionId, Vec<String>>>,
}

impl Default for TopicCartridge {
    fn default() -> Self {
        Self::new()
    }
}

impl TopicCartridge {
    /// Create a new topic cartridge
    pub fn new() -> Self {
        Self {
            topics: RwLock::new(HashMap::new()),
            by_category: RwLock::new(HashMap::new()),
            by_keyword: RwLock::new(HashMap::new()),
            by_commit: RwLock::new(HashMap::new()),
        }
    }

    /// Insert a topic into the cartridge
    pub fn insert(&self, topic: Topic) -> Result<()> {
        let category = topic.category.as_str().to_string();
        let keywords = topic.keywords.clone();
        let id = topic.id.clone();
        let commit_id = topic.commit_id;

        // Insert main topic
        {
            let mut topics = self.topics.write()
                .map_err(|e| DbError::Io(IoError::InternalError(format!("Failed to acquire write lock: {}", e))))?;
            topics.insert(id.clone(), topic);
        }

        // Update category index
        {
            let mut by_category = self.by_category.write()
                .map_err(|e| DbError::Io(IoError::InternalError(format!("Failed to acquire write lock: {}", e))))?;
            by_category.entry(category).or_insert_with(Vec::new).push(id.clone());
        }

        // Update keyword indices
        {
            let mut by_keyword = self.by_keyword.write()
                .map_err(|e| DbError::Io(IoError::InternalError(format!("Failed to acquire write lock: {}", e))))?;
            for keyword in keywords {
                by_keyword.entry(keyword.to_lowercase()).or_insert_with(Vec::new).push(id.clone());
            }
        }

        // Update commit index
        {
            let mut by_commit = self.by_commit.write()
                .map_err(|e| DbError::Io(IoError::InternalError(format!("Failed to acquire write lock: {}", e))))?;
            by_commit.entry(commit_id).or_insert_with(Vec::new).push(id);
        }

        Ok(())
    }

    /// Get topic by ID
    pub fn get(&self, id: &str) -> Result<Option<Topic>> {
        let topics = self.topics.read()
            .map_err(|e| DbError::Io(IoError::InternalError(format!("Failed to acquire read lock: {}", e))))?;
        Ok(topics.get(id).cloned())
    }

    /// Get all topics in a category
    pub fn get_by_category(&self, category: &str) -> Result<Vec<Topic>> {
        let by_category = self.by_category.read()
            .map_err(|e| DbError::Io(IoError::InternalError(format!("Failed to acquire read lock: {}", e))))?;

        let ids = by_category.get(category).cloned().unwrap_or_default();

        let topics = self.topics.read()
            .map_err(|e| DbError::Io(IoError::InternalError(format!("Failed to acquire read lock: {}", e))))?;

        let result = ids.iter()
            .filter_map(|id| topics.get(id).cloned())
            .collect();

        Ok(result)
    }

    /// Get topics matching a keyword
    pub fn get_by_keyword(&self, keyword: &str) -> Result<Vec<Topic>> {
        let by_keyword = self.by_keyword.read()
            .map_err(|e| DbError::Io(IoError::InternalError(format!("Failed to acquire read lock: {}", e))))?;

        let keyword_lower = keyword.to_lowercase();
        let ids = by_keyword.get(&keyword_lower).cloned().unwrap_or_default();

        let topics = self.topics.read()
            .map_err(|e| DbError::Io(IoError::InternalError(format!("Failed to acquire read lock: {}", e))))?;

        let result = ids.iter()
            .filter_map(|id| topics.get(id).cloned())
            .collect();

        Ok(result)
    }

    /// Get all topics from a specific commit
    pub fn get_by_commit(&self, commit_id: TransactionId) -> Result<Vec<Topic>> {
        let by_commit = self.by_commit.read()
            .map_err(|e| DbError::Io(IoError::InternalError(format!("Failed to acquire read lock: {}", e))))?;

        let ids = by_commit.get(&commit_id).cloned().unwrap_or_default();

        let topics = self.topics.read()
            .map_err(|e| DbError::Io(IoError::InternalError(format!("Failed to acquire read lock: {}", e))))?;

        let result = ids.iter()
            .filter_map(|id| topics.get(id).cloned())
            .collect();

        Ok(result)
    }

    /// Get all topics
    pub fn get_all(&self) -> Result<Vec<Topic>> {
        let topics = self.topics.read()
            .map_err(|e| DbError::Io(IoError::InternalError(format!("Failed to acquire read lock: {}", e))))?;

        Ok(topics.values().cloned().collect())
    }

    /// Count total topics
    pub fn count(&self) -> Result<usize> {
        let topics = self.topics.read()
            .map_err(|e| DbError::Io(IoError::InternalError(format!("Failed to acquire read lock: {}", e))))?;
        Ok(topics.len())
    }

    /// Clear all topics
    pub fn clear(&self) -> Result<()> {
        {
            let mut topics = self.topics.write()
                .map_err(|e| DbError::Io(IoError::InternalError(format!("Failed to acquire write lock: {}", e))))?;
            topics.clear();
        }
        {
            let mut by_category = self.by_category.write()
                .map_err(|e| DbError::Io(IoError::InternalError(format!("Failed to acquire write lock: {}", e))))?;
            by_category.clear();
        }
        {
            let mut by_keyword = self.by_keyword.write()
                .map_err(|e| DbError::Io(IoError::InternalError(format!("Failed to acquire write lock: {}", e))))?;
            by_keyword.clear();
        }
        {
            let mut by_commit = self.by_commit.write()
                .map_err(|e| DbError::Io(IoError::InternalError(format!("Failed to acquire write lock: {}", e))))?;
            by_commit.clear();
        }

        Ok(())
    }

    /// Get topic by name
    pub fn get_by_name(&self, name: &str) -> Result<Option<Topic>> {
        let topics = self.topics.read()
            .map_err(|e| DbError::Io(IoError::InternalError(format!("Failed to acquire read lock: {}", e))))?;

        // Find topic by name
        for topic in topics.values() {
            if topic.name == name {
                return Ok(Some(topic.clone()));
            }
        }

        Ok(None)
    }

    /// Get all topics
    pub fn get_all_topics(&self) -> Result<Vec<Topic>> {
        self.get_all()
    }

    /// Add entity to topic
    pub fn add_entity_to_topic(&self, topic_id: &str, entity_id: String) -> Result<()> {
        let mut topics = self.topics.write()
            .map_err(|e| DbError::Io(IoError::InternalError(format!("Failed to acquire write lock: {}", e))))?;

        if let Some(topic) = topics.get_mut(topic_id) {
            if !topic.entity_ids.contains(&entity_id) {
                topic.entity_ids.push(entity_id);
            }
            Ok(())
        } else {
            Err(DbError::Io(IoError::FileNotFound { path: format!("{}", topic_id) }))
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::types::TransactionId;

    #[test]
    fn test_topic_category_conversion() {
        assert_eq!(TopicCategory::Feature.as_str(), "feature");
        assert_eq!(TopicCategory::from_str("feature"), TopicCategory::Feature);
        assert_eq!(TopicCategory::from_str("custom"), TopicCategory::Custom("custom".to_string()));
    }

    #[test]
    fn test_topic_cartridge_insert() {
        let cartridge = TopicCartridge::new();
        let topic = Topic::new(
            "topic-1".to_string(),
            "BTree Implementation".to_string(),
            TopicCategory::Feature,
            vec!["btree".to_string(), "storage".to_string()],
            TransactionId::new(1),
            0.9,
        );

        cartridge.insert(topic).unwrap();
        assert_eq!(cartridge.count().unwrap(), 1);
    }

    #[test]
    fn test_topic_cartridge_get() {
        let cartridge = TopicCartridge::new();
        let topic = Topic::new(
            "topic-1".to_string(),
            "BTree Implementation".to_string(),
            TopicCategory::Feature,
            vec!["btree".to_string(), "storage".to_string()],
            TransactionId::new(1),
            0.9,
        );

        cartridge.insert(topic.clone()).unwrap();

        // Get by ID
        let retrieved = cartridge.get("topic-1").unwrap().unwrap();
        assert_eq!(retrieved.id, "topic-1");
        assert_eq!(retrieved.name, "BTree Implementation");

        // Get by category
        let by_category = cartridge.get_by_category("feature").unwrap();
        assert_eq!(by_category.len(), 1);

        // Get by keyword
        let by_keyword = cartridge.get_by_keyword("btree").unwrap();
        assert_eq!(by_keyword.len(), 1);

        // Get by commit
        let by_commit = cartridge.get_by_commit(TransactionId::new(1)).unwrap();
        assert_eq!(by_commit.len(), 1);
    }

    #[test]
    fn test_topic_matches_keyword() {
        let topic = Topic::new(
            "topic-1".to_string(),
            "BTree Implementation".to_string(),
            TopicCategory::Feature,
            vec!["btree".to_string(), "storage".to_string()],
            TransactionId::new(1),
            0.9,
        );

        assert!(topic.matches_keyword("btree"));
        assert!(topic.matches_keyword("BTREE")); // Case insensitive
        assert!(!topic.matches_keyword("auth"));
    }
}
