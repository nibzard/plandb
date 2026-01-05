//! Entity Extractor Plugin
//!
//! Extracts entities, topics, and relationships from database commits
//! using LLM function calling. Stores results in structured memory cartridges.

use crate::cartridges::{
    entity::{Entity, EntityCartridge, EntityType, FileEntity, FunctionEntity, PersonEntity, ConfigEntity},
    topic::{Topic, TopicCartridge, TopicCategory},
    relationship::{Relationship, RelationshipCartridge, RelationshipType},
};
use crate::error::{Error as DbError, IoError, Result};
use crate::llm::{
    ChatMessage, ChatRole, FunctionCallBehavior, FunctionDefinition, LlmProvider,
};
use crate::plugins::types::{CommitEvent, Plugin, PluginContext};
use crate::types::TransactionId;
use async_trait::async_trait;
use serde::{Deserialize, Serialize};
use std::sync::Arc;
use tokio::sync::RwLock;

/// Configuration for entity extractor plugin
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct EntityExtractorConfig {
    /// Minimum confidence threshold for storing entities
    pub min_confidence: f32,

    /// Enable topic extraction
    pub enable_topic_extraction: bool,

    /// Enable relationship detection
    pub enable_relationship_detection: bool,

    /// Maximum entities to extract per commit
    pub max_entities_per_commit: usize,

    /// LLM model to use for extraction
    pub model: String,

    /// Extraction timeout in seconds
    pub timeout_seconds: u64,
}

impl Default for EntityExtractorConfig {
    fn default() -> Self {
        Self {
            min_confidence: 0.5,
            enable_topic_extraction: true,
            enable_relationship_detection: true,
            max_entities_per_commit: 100,
            model: "gpt-4-turbo".to_string(),
            timeout_seconds: 30,
        }
    }
}

/// Extracted entities from LLM function call
#[derive(Debug, Deserialize)]
struct ExtractedEntities {
    files: Vec<ExtractedFile>,
    functions: Vec<ExtractedFunction>,
    people: Vec<ExtractedPerson>,
    configs: Vec<ExtractedConfig>,
}

#[derive(Debug, Deserialize)]
struct ExtractedFile {
    path: String,
    language: String,
    size: Option<u64>,
    #[serde(default)]
    confidence: f32,
}

#[derive(Debug, Deserialize)]
struct ExtractedFunction {
    name: String,
    signature: String,
    file_path: String,
    line_start: Option<u32>,
    line_end: Option<u32>,
    #[serde(default)]
    confidence: f32,
}

#[derive(Debug, Deserialize)]
struct ExtractedPerson {
    name: String,
    role: String,
    contact: Option<String>,
    #[serde(default)]
    confidence: f32,
}

#[derive(Debug, Deserialize)]
struct ExtractedConfig {
    key: String,
    value: String,
    source: String,
    #[serde(default)]
    confidence: f32,
}

/// Extracted topics from LLM function call
#[derive(Debug, Deserialize)]
struct ExtractedTopics {
    topics: Vec<ExtractedTopic>,
}

#[derive(Debug, Deserialize)]
struct ExtractedTopic {
    name: String,
    category: String,
    keywords: Vec<String>,
    description: Option<String>,
    #[serde(default)]
    confidence: f32,
}

/// Extracted relationships from LLM function call
#[derive(Debug, Deserialize)]
struct ExtractedRelationships {
    relationships: Vec<ExtractedRelationship>,
}

#[derive(Debug, Deserialize)]
struct ExtractedRelationship {
    from_entity: String,
    to_entity: String,
    rel_type: String,
    #[serde(default)]
    weight: f32,
    #[serde(default)]
    confidence: f32,
}

/// Entity extractor plugin
#[derive(Debug)]
pub struct EntityExtractorPlugin {
    /// LLM provider for function calling
    llm: Arc<dyn LlmProvider>,

    /// Entity cartridge storage
    entity_cartridge: Arc<EntityCartridge>,

    /// Topic cartridge storage
    topic_cartridge: Arc<TopicCartridge>,

    /// Relationship cartridge storage
    relationship_cartridge: Arc<RelationshipCartridge>,

    /// Plugin configuration
    config: EntityExtractorConfig,

    /// Entity counter for generating IDs
    entity_counter: Arc<RwLock<usize>>,

    /// Topic counter for generating IDs
    topic_counter: Arc<RwLock<usize>>,

    /// Relationship counter for generating IDs
    rel_counter: Arc<RwLock<usize>>,
}

impl EntityExtractorPlugin {
    /// Create a new entity extractor plugin
    pub fn new(
        llm: Arc<dyn LlmProvider>,
        config: EntityExtractorConfig,
    ) -> Self {
        Self {
            llm,
            entity_cartridge: Arc::new(EntityCartridge::new()),
            topic_cartridge: Arc::new(TopicCartridge::new()),
            relationship_cartridge: Arc::new(RelationshipCartridge::new()),
            config,
            entity_counter: Arc::new(RwLock::new(0)),
            topic_counter: Arc::new(RwLock::new(0)),
            rel_counter: Arc::new(RwLock::new(0)),
        }
    }

    /// Get entity cartridge reference
    pub fn entity_cartridge(&self) -> &Arc<EntityCartridge> {
        &self.entity_cartridge
    }

    /// Get topic cartridge reference
    pub fn topic_cartridge(&self) -> &Arc<TopicCartridge> {
        &self.topic_cartridge
    }

    /// Get relationship cartridge reference
    pub fn relationship_cartridge(&self) -> &Arc<RelationshipCartridge> {
        &self.relationship_cartridge
    }

    /// Extract entities from a commit event
    async fn extract_entities_from_commit(
        &self,
        event: &CommitEvent,
    ) -> Result<Vec<Entity>> {
        let mut entities = Vec::new();

        // Build prompt from mutations
        let prompt = self.build_extraction_prompt(event);

        // Define function schema
        let function = FunctionDefinition {
            name: "extract_entities".to_string(),
            description: "Extract entities from database commit mutations".to_string(),
            parameters: serde_json::json!({
                "type": "object",
                "properties": {
                    "files": {
                        "type": "array",
                        "items": {
                            "type": "object",
                            "properties": {
                                "path": {"type": "string"},
                                "language": {"type": "string"},
                                "size": {"type": "integer"},
                                "confidence": {"type": "number"}
                            },
                            "required": ["path", "language"]
                        }
                    },
                    "functions": {
                        "type": "array",
                        "items": {
                            "type": "object",
                            "properties": {
                                "name": {"type": "string"},
                                "signature": {"type": "string"},
                                "file_path": {"type": "string"},
                                "line_start": {"type": "integer"},
                                "line_end": {"type": "integer"},
                                "confidence": {"type": "number"}
                            },
                            "required": ["name", "signature", "file_path"]
                        }
                    },
                    "people": {
                        "type": "array",
                        "items": {
                            "type": "object",
                            "properties": {
                                "name": {"type": "string"},
                                "role": {"type": "string"},
                                "contact": {"type": "string"},
                                "confidence": {"type": "number"}
                            },
                            "required": ["name", "role"]
                        }
                    },
                    "configs": {
                        "type": "array",
                        "items": {
                            "type": "object",
                            "properties": {
                                "key": {"type": "string"},
                                "value": {"type": "string"},
                                "source": {"type": "string"},
                                "confidence": {"type": "number"}
                            },
                            "required": ["key", "value", "source"]
                        }
                    }
                }
            }),
        };

        let request = crate::llm::FunctionCallRequest {
            model: self.config.model.clone(),
            messages: vec![
                ChatMessage {
                    role: ChatRole::System,
                    content: "You are an expert code analyst. Extract entities from commit mutations.".to_string(),
                },
                ChatMessage {
                    role: ChatRole::User,
                    content: prompt,
                },
            ],
            functions: vec![function],
            function_call: FunctionCallBehavior::Auto,
            temperature: 0.3,
            max_tokens: Some(2000),
        };

        match self.llm.function_call(request).await {
            Ok(response) => {
                if let Some(call) = response.function_call {
                    if call.name == "extract_entities" {
                        if let Ok(extracted) = serde_json::from_str::<ExtractedEntities>(&call.arguments) {
                            entities = self.parse_extracted_entities(extracted, event.txn_id)?;
                        }
                    }
                }
            }
            Err(e) => {
                eprintln!("Entity extraction failed: {:?}", e);
                // Continue without entities rather than failing the commit
            }
        }

        Ok(entities)
    }

    /// Build extraction prompt from commit event
    fn build_extraction_prompt(&self, event: &CommitEvent) -> String {
        let mut prompt = format!("Extract entities from this commit (Transaction ID: {}):\n\n", event.txn_id);

        for mutation in &event.mutations {
            prompt.push_str(&format!(
                "Mutation: {} on key {:?}\n",
                mutation.mutation_type, mutation.key
            ));
            if let Some(value) = &mutation.value {
                prompt.push_str(&format!("Value: {}\n", value));
            }
        }

        prompt.push_str("\nExtract files, functions, people, and configs. Assign confidence scores (0.0-1.0).");
        prompt
    }

    /// Parse extracted entities and convert to internal format
    fn parse_extracted_entities(
        &self,
        extracted: ExtractedEntities,
        commit_id: TransactionId,
    ) -> Result<Vec<Entity>> {
        let mut entities = Vec::new();

        // Process files
        for file in extracted.files {
            if file.confidence >= self.config.min_confidence {
                let id = self.generate_entity_id("file");
                let file_entity = FileEntity::new(
                    id,
                    file.path,
                    file.language,
                    file.size.unwrap_or(0),
                    commit_id,
                    file.confidence,
                );
                entities.push(file_entity.entity);
            }
        }

        // Process functions
        for func in extracted.functions {
            if func.confidence >= self.config.min_confidence {
                let id = self.generate_entity_id("function");
                let func_entity = FunctionEntity::new(
                    id,
                    func.name,
                    func.signature,
                    func.file_path,
                    func.line_start.unwrap_or(0),
                    func.line_end.unwrap_or(0),
                    commit_id,
                    func.confidence,
                );
                entities.push(func_entity.entity);
            }
        }

        // Process people
        for person in extracted.people {
            if person.confidence >= self.config.min_confidence {
                let id = self.generate_entity_id("person");
                let person_entity = PersonEntity::new(
                    id,
                    person.name,
                    person.role,
                    person.contact,
                    commit_id,
                    person.confidence,
                );
                entities.push(person_entity.entity);
            }
        }

        // Process configs
        for config in extracted.configs {
            if config.confidence >= self.config.min_confidence {
                let id = self.generate_entity_id("config");
                let config_entity = ConfigEntity::new(
                    id,
                    config.key,
                    config.value,
                    config.source,
                    commit_id,
                    config.confidence,
                );
                entities.push(config_entity.entity);
            }
        }

        Ok(entities)
    }

    /// Extract topics from a commit event
    async fn extract_topics_from_commit(
        &self,
        event: &CommitEvent,
    ) -> Result<Vec<Topic>> {
        if !self.config.enable_topic_extraction {
            return Ok(Vec::new());
        }

        let mut topics = Vec::new();

        // Build prompt
        let prompt = format!(
            "Extract topics from this commit (Transaction ID: {}):\n\n{:?}\n\n",
            event.txn_id, event.mutations
        );
        let prompt = format!(
            "{}Identify main topics, categories (feature/bugfix/refactor/infrastructure/documentation/performance/testing), and keywords.",
            prompt
        );

        // Define function schema
        let function = FunctionDefinition {
            name: "extract_topics".to_string(),
            description: "Extract topics from database commit".to_string(),
            parameters: serde_json::json!({
                "type": "object",
                "properties": {
                    "topics": {
                        "type": "array",
                        "items": {
                            "type": "object",
                            "properties": {
                                "name": {"type": "string"},
                                "category": {"type": "string"},
                                "keywords": {"type": "array", "items": {"type": "string"}},
                                "description": {"type": "string"},
                                "confidence": {"type": "number"}
                            },
                            "required": ["name", "category", "keywords"]
                        }
                    }
                }
            }),
        };

        let request = crate::llm::FunctionCallRequest {
            model: self.config.model.clone(),
            messages: vec![
                ChatMessage {
                    role: ChatRole::System,
                    content: "You are an expert code analyst. Identify topics and categories.".to_string(),
                },
                ChatMessage {
                    role: ChatRole::User,
                    content: prompt,
                },
            ],
            functions: vec![function],
            function_call: FunctionCallBehavior::Auto,
            temperature: 0.3,
            max_tokens: Some(1500),
        };

        match self.llm.function_call(request).await {
            Ok(response) => {
                if let Some(call) = response.function_call {
                    if call.name == "extract_topics" {
                        if let Ok(extracted) = serde_json::from_str::<ExtractedTopics>(&call.arguments) {
                            topics = self.parse_extracted_topics(extracted, event.txn_id)?;
                        }
                    }
                }
            }
            Err(e) => {
                eprintln!("Topic extraction failed: {:?}", e);
            }
        }

        Ok(topics)
    }

    /// Parse extracted topics
    fn parse_extracted_topics(
        &self,
        extracted: ExtractedTopics,
        commit_id: TransactionId,
    ) -> Result<Vec<Topic>> {
        let mut topics = Vec::new();

        for topic in extracted.topics {
            if topic.confidence >= self.config.min_confidence {
                let id = self.generate_topic_id();
                let category = TopicCategory::from_str(&topic.category);
                let mut topic_obj = Topic::new(
                    id,
                    topic.name,
                    category,
                    topic.keywords,
                    commit_id,
                    topic.confidence,
                );
                if let Some(description) = topic.description {
                    topic_obj = topic_obj.with_description(description);
                }
                topics.push(topic_obj);
            }
        }

        Ok(topics)
    }

    /// Extract relationships from entities
    async fn extract_relationships_from_commit(
        &self,
        event: &CommitEvent,
        entities: &[Entity],
        topics: &[Topic],
    ) -> Result<Vec<Relationship>> {
        if !self.config.enable_relationship_detection {
            return Ok(Vec::new());
        }

        let mut relationships = Vec::new();

        // Simple structural relationships
        for entity in entities {
            if entity.entity_type == EntityType::Function {
                if let Some(file_path) = entity.metadata.get("file_path") {
                    // Find file entity
                    if let Some(file_entity) = self.find_entity_by_name(file_path) {
                        let rel_id = self.generate_rel_id();
                        let rel = Relationship::new(
                            rel_id,
                            file_entity.id.clone(),
                            entity.id.clone(),
                            RelationshipType::Contains,
                            1.0,
                            event.txn_id,
                            1.0,
                        );
                        relationships.push(rel);
                    }
                }
            }
        }

        // Entity-topic relationships
        for entity in entities {
            for topic in topics {
                // Check if entity matches topic keywords
                if topic.matches_keyword(&entity.name.to_lowercase()) {
                    let rel_id = self.generate_rel_id();
                    let rel = Relationship::new(
                        rel_id,
                        entity.id.clone(),
                        topic.id.clone(),
                        RelationshipType::RelatedTo,
                        0.8,
                        event.txn_id,
                        0.8,
                    );
                    relationships.push(rel);
                }
            }
        }

        Ok(relationships)
    }

    /// Find entity by name
    fn find_entity_by_name(&self, name: &str) -> Option<Entity> {
        self.entity_cartridge.get_by_name(name).ok().flatten()
    }

    /// Generate unique entity ID
    fn generate_entity_id(&self, prefix: &str) -> String {
        let counter = self.entity_counter.clone();
        let mut counter_guard = match tokio::runtime::Handle::try_current() {
            Ok(handle) => {
                // In async context
                tokio::task::block_in_place(|| {
                    handle.block_on(async {
                        let mut val = counter.write().await;
                        *val += 1;
                        *val
                    })
                })
            }
            Err(_) => {
                // Not in async context
                let mut val = counter.try_write().unwrap();
                *val += 1;
                *val
            }
        };
        format!("{}-{}", prefix, counter_guard)
    }

    /// Generate unique topic ID
    fn generate_topic_id(&self) -> String {
        let counter = self.topic_counter.clone();
        let mut counter_guard = match tokio::runtime::Handle::try_current() {
            Ok(handle) => {
                tokio::task::block_in_place(|| {
                    handle.block_on(async {
                        let mut val = counter.write().await;
                        *val += 1;
                        *val
                    })
                })
            }
            Err(_) => {
                let mut val = counter.try_write().unwrap();
                *val += 1;
                *val
            }
        };
        format!("topic-{}", counter_guard)
    }

    /// Generate unique relationship ID
    fn generate_rel_id(&self) -> String {
        let counter = self.rel_counter.clone();
        let mut counter_guard = match tokio::runtime::Handle::try_current() {
            Ok(handle) => {
                tokio::task::block_in_place(|| {
                    handle.block_on(async {
                        let mut val = counter.write().await;
                        *val += 1;
                        *val
                    })
                })
            }
            Err(_) => {
                let mut val = counter.try_write().unwrap();
                *val += 1;
                *val
            }
        };
        format!("rel-{}", counter_guard)
    }
}

#[async_trait]
impl Plugin for EntityExtractorPlugin {
    fn name(&self) -> &str {
        "entity_extractor"
    }

    fn version(&self) -> &str {
        env!("CARGO_PKG_VERSION")
    }

    async fn on_init(&mut self, _context: &PluginContext) -> Result<()> {
        // Validate configuration
        if self.config.min_confidence < 0.0 || self.config.min_confidence > 1.0 {
            return Err(DbError::Validation(crate::error::ValidationError::InvalidInput)(
                "min_confidence must be between 0.0 and 1.0".to_string(),
            ));
        }

        // Check LLM provider availability
        let health = self.llm.health_check().await?;
        if !health.is_healthy() {
            return Err(DbError::Io(IoError::InternalError(format!((
                "LLM provider not healthy: {:?}",
                health
            )));
        }

        Ok(())
    }

    async fn on_commit(&mut self, event: &CommitEvent) -> Result<()> {
        // Extract entities
        let entities = self.extract_entities_from_commit(event).await?;

        // Store entities
        for entity in &entities {
            self.entity_cartridge.insert(entity.clone())?;
        }

        // Extract topics
        let topics = self.extract_topics_from_commit(event).await?;

        // Store topics
        for topic in &topics {
            self.topic_cartridge.insert(topic.clone())?;
        }

        // Extract relationships
        let relationships = self.extract_relationships_from_commit(event, &entities, &topics).await?;

        // Store relationships
        for relationship in &relationships {
            self.relationship_cartridge.insert(relationship.clone())?;
        }

        Ok(())
    }

    async fn on_query(&mut self, _event: &crate::plugins::types::QueryEvent) -> Result<crate::plugins::types::QueryResponse> {
        // Entity extraction doesn't modify queries
        Ok(crate::plugins::types::QueryResponse::PassThrough)
    }

    async fn on_schedule(&mut self, _event: &crate::plugins::types::ScheduleEvent) -> Result<()> {
        // Optional: Periodic maintenance tasks
        // - Rebuild entity indices
        // - Validate low-confidence entities
        // - Update topic categories
        Ok(())
    }

    async fn on_shutdown(&mut self) -> Result<()> {
        // Flush any pending data
        Ok(())
    }
}
