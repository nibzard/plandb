//! Entity Linking for Natural Language Queries
//!
//! Links entity references in natural language queries to entries in
//! the entity and topic cartridges using exact, fuzzy, and semantic matching.

use crate::cartridges::{Entity, EntityCartridge, EntityType, Topic, TopicCartridge};
use crate::queries::types::{LinkResult, MatchType};
use crate::{Error, Result};
use std::sync::Arc;
use tokio::sync::RwLock;

/// Configuration for entity linker
#[derive(Debug, Clone)]
pub struct EntityLinkerConfig {
    /// Minimum similarity threshold for fuzzy matching
    pub fuzzy_threshold: f32,

    /// Maximum number of results to return
    pub max_results: usize,

    /// Enable semantic matching
    pub enable_semantic: bool,
}

impl Default for EntityLinkerConfig {
    fn default() -> Self {
        Self {
            fuzzy_threshold: 0.7,
            max_results: 10,
            enable_semantic: true,
        }
    }
}

/// Entity linker for resolving entity references
pub struct EntityLinker {
    /// Entity cartridge
    entity_cartridge: Arc<RwLock<EntityCartridge>>,

    /// Topic cartridge
    topic_cartridge: Arc<RwLock<TopicCartridge>>,

    /// Configuration
    config: EntityLinkerConfig,
}

impl EntityLinker {
    /// Create new entity linker
    pub fn new(
        entity_cartridge: Arc<RwLock<EntityCartridge>>,
        topic_cartridge: Arc<RwLock<TopicCartridge>>,
        config: EntityLinkerConfig,
    ) -> Self {
        Self {
            entity_cartridge,
            topic_cartridge,
            config,
        }
    }

    /// Link entity reference to cartridge entry
    pub async fn link(
        &self,
        text: &str,
        entity_type: EntityType,
    ) -> Result<Vec<LinkResult>> {
        // 1. Exact match lookup
        if let Some(result) = self.exact_match(text, entity_type)? {
            return Ok(vec![result]);
        }

        let mut results = Vec::new();

        // 2. Fuzzy match (Levenshtein distance)
        let fuzzy_matches = self.fuzzy_match(text, entity_type)?;
        results.extend(fuzzy_matches);

        // 3. Semantic match (using topic keywords)
        if self.config.enable_semantic {
            let semantic_matches = self.semantic_match(text, entity_type)?;
            results.extend(semantic_matches);
        }

        // 4. Partial match
        let partial_matches = self.partial_match(text, entity_type)?;
        results.extend(partial_matches);

        // 5. Sort by confidence and limit
        results.sort_by(|a, b| b.confidence.partial_cmp(&a.confidence).unwrap());
        results.truncate(self.config.max_results);

        Ok(results)
    }

    /// Exact match lookup
    fn exact_match(&self, text: &str, entity_type: EntityType) -> Result<Option<LinkResult>> {
        match entity_type {
            EntityType::Person | EntityType::File | EntityType::Function | EntityType::Config => {
                let cartridge = self.entity_cartridge.blocking_read();
                if let Ok(Some(entity)) = cartridge.get_by_name(text) {
                    return Ok(Some(LinkResult {
                        entity_id: entity.id().to_string(),
                        confidence: 1.0,
                        match_type: MatchType::Exact,
                    }));
                }
            }
            EntityType::Topic => {
                let cartridge = self.topic_cartridge.blocking_read();
                if let Ok(Some(topic)) = cartridge.get_by_name(text) {
                    return Ok(Some(LinkResult {
                        entity_id: topic.id.clone(),
                        confidence: 1.0,
                        match_type: MatchType::Exact,
                    }));
                }
            }
        }

        Ok(None)
    }

    /// Fuzzy match using edit distance
    fn fuzzy_match(&self, text: &str, entity_type: EntityType) -> Result<Vec<LinkResult>> {
        let mut results = Vec::new();

        match entity_type {
            EntityType::Person | EntityType::File | EntityType::Function | EntityType::Config => {
                let cartridge = self.entity_cartridge.blocking_read();
                let entities: Vec<Entity> = match entity_type {
                    EntityType::Person => cartridge.get_all_persons()?.into_iter().map(|e| e.clone()).collect(),
                    EntityType::File => cartridge.get_all_files()?.into_iter().map(|e| e.clone()).collect(),
                    EntityType::Function => cartridge.get_all_functions()?.into_iter().map(|e| e.clone()).collect(),
                    EntityType::Config => cartridge.get_all_configs()?.into_iter().map(|e| e.clone()).collect(),
                    _ => return Ok(results),
                };

                for entity in entities {
                    let name = entity.name();
                    let distance = levenshtein_distance(text, name);
                    let max_len = text.len().max(name.len());
                    let similarity = if max_len > 0 {
                        1.0 - (distance as f32 / max_len as f32)
                    } else {
                        1.0
                    };

                    if similarity >= self.config.fuzzy_threshold {
                        results.push(LinkResult {
                            entity_id: entity.id().to_string(),
                            confidence: similarity,
                            match_type: MatchType::Fuzzy,
                        });
                    }
                }
            }
            EntityType::Topic => {
                // Topics use semantic matching instead
            }
        }

        Ok(results)
    }

    /// Semantic match using topic keywords
    fn semantic_match(&self, text: &str, entity_type: EntityType) -> Result<Vec<LinkResult>> {
        let mut results = Vec::new();

        if entity_type != EntityType::Topic {
            return Ok(results);
        }

        let cartridge = self.topic_cartridge.blocking_read();
        let topics = cartridge.get_all_topics()?;

        for topic in topics {
            // Check if text matches topic keywords
            for keyword in &topic.keywords {
                let keyword_similarity = text_similarity(text, keyword);

                if keyword_similarity >= self.config.fuzzy_threshold {
                    results.push(LinkResult {
                        entity_id: topic.id.clone(),
                        confidence: keyword_similarity,
                        match_type: MatchType::Semantic,
                    });
                    break;
                }
            }
        }

        Ok(results)
    }

    /// Partial string match
    fn partial_match(&self, text: &str, entity_type: EntityType) -> Result<Vec<LinkResult>> {
        let mut results = Vec::new();

        match entity_type {
            EntityType::Person | EntityType::File | EntityType::Function | EntityType::Config => {
                let cartridge = self.entity_cartridge.blocking_read();
                let entities: Vec<Entity> = match entity_type {
                    EntityType::Person => cartridge.get_all_persons()?.into_iter().map(|e| e.clone()).collect(),
                    EntityType::File => cartridge.get_all_files()?.into_iter().map(|e| e.clone()).collect(),
                    EntityType::Function => cartridge.get_all_functions()?.into_iter().map(|e| e.clone()).collect(),
                    EntityType::Config => cartridge.get_all_configs()?.into_iter().map(|e| e.clone()).collect(),
                    _ => return Ok(results),
                };

                for entity in entities {
                    let name = entity.name();

                    // Check if text is substring of name or vice versa
                    let contains = if text.len() < name.len() {
                        name.to_lowercase().contains(&text.to_lowercase())
                    } else {
                        text.to_lowercase().contains(&name.to_lowercase())
                    };

                    if contains {
                        results.push(LinkResult {
                            entity_id: entity.id().to_string(),
                            confidence: 0.6,
                            match_type: MatchType::Partial,
                        });
                    }
                }
            }
            EntityType::Topic => {
                let cartridge = self.topic_cartridge.blocking_read();
                let topics = cartridge.get_all_topics()?;

                for topic in topics {
                    if text.to_lowercase().contains(&topic.name.to_lowercase())
                        || topic.name.to_lowercase().contains(&text.to_lowercase())
                    {
                        results.push(LinkResult {
                            entity_id: topic.id.clone(),
                            confidence: 0.6,
                            match_type: MatchType::Partial,
                        });
                    }
                }
            }
        }

        Ok(results)
    }
}

/// Calculate Levenshtein distance between two strings
fn levenshtein_distance(a: &str, b: &str) -> usize {
    let a_chars: Vec<char> = a.chars().collect();
    let b_chars: Vec<char> = b.chars().collect();
    let m = a_chars.len();
    let n = b_chars.len();

    let mut dp = vec![vec![0; n + 1]; m + 1];

    for i in 0..=m {
        dp[i][0] = i;
    }

    for j in 0..=n {
        dp[0][j] = j;
    }

    for i in 1..=m {
        for j in 1..=n {
            if a_chars[i - 1] == b_chars[j - 1] {
                dp[i][j] = dp[i - 1][j - 1];
            } else {
                dp[i][j] = 1 + [dp[i - 1][j], dp[i][j - 1], dp[i - 1][j - 1]]
                    .iter()
                    .min()
                    .unwrap();
            }
        }
    }

    dp[m][n]
}

/// Calculate text similarity (simple word overlap)
fn text_similarity(a: &str, b: &str) -> f32 {
    let a_lower = a.to_lowercase();
    let b_lower = b.to_lowercase();

    let a_words: Vec<&str> = a_lower.split_whitespace().collect();
    let b_words: Vec<&str> = b_lower.split_whitespace().collect();

    if a_words.is_empty() || b_words.is_empty() {
        return 0.0;
    }

    let mut intersection = 0;
    for word_a in &a_words {
        if b_words.contains(word_a) {
            intersection += 1;
        }
    }

    let union = a_words.len() + b_words.len() - intersection;
    if union == 0 {
        return 0.0;
    }

    intersection as f32 / union as f32
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::cartridges::{FileEntity, FunctionEntity};

    #[test]
    fn test_levenshtein_distance() {
        assert_eq!(levenshtein_distance("kitten", "sitting"), 3);
        assert_eq!(levenshtein_distance("test", "test"), 0);
        assert_eq!(levenshtein_distance("", "test"), 4);
    }

    #[test]
    fn test_text_similarity() {
        let sim = text_similarity("storage layer", "storage");
        assert!(sim > 0.0);

        let sim = text_similarity("btree implementation", "btree");
        assert!(sim > 0.0);
    }

    fn create_test_cartridge() -> EntityCartridge {
        EntityCartridge::new()
    }

    #[tokio::test]
    async fn test_exact_match() {
        let cartridge = Arc::new(RwLock::new(create_test_cartridge()));
        let topic_cartridge = Arc::new(RwLock::new(TopicCartridge::new()));

        // Add test entity - use base Entity
        let entity = Entity::new(
            "file-1".to_string(),
            EntityType::File,
            "db.zig".to_string(),
            crate::types::TransactionId::new(1),
            1.0,
        );

        cartridge.write().await.insert(entity).unwrap();

        let linker = EntityLinker::new(cartridge, topic_cartridge, EntityLinkerConfig::default());

        let results = linker.link("db.zig", EntityType::File).await.unwrap();

        assert!(!results.is_empty());
        assert_eq!(results[0].match_type, MatchType::Exact);
        assert_eq!(results[0].confidence, 1.0);
    }

    #[tokio::test]
    async fn test_fuzzy_match() {
        let cartridge = Arc::new(RwLock::new(create_test_cartridge()));
        let topic_cartridge = Arc::new(RwLock::new(TopicCartridge::new()));

        let entity = Entity::new(
            "file-1".to_string(),
            EntityType::File,
            "database.rs".to_string(),
            crate::types::TransactionId::new(1),
            1.0,
        );

        cartridge.write().await.insert(entity).unwrap();

        let linker = EntityLinker::new(cartridge, topic_cartridge, EntityLinkerConfig {
            fuzzy_threshold: 0.5,
            ..Default::default()
        });

        let results = linker.link("db.rs", EntityType::File).await.unwrap();

        // Should find fuzzy match
        assert!(!results.is_empty());
        assert!(results.iter().any(|r| r.match_type == MatchType::Fuzzy));
    }
}
