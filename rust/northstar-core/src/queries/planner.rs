//! Natural Language Query Planner
//!
//! Translates natural language queries into structured database operations
//! using LLM function calling and cartridge integration.

use crate::cartridges::{
    Entity, EntityCartridge, EntityType, Relationship, RelationshipCartridge, Topic,
    TopicCartridge,
};
use crate::llm::{
    ChatMessage, ChatRequest, ChatResponse, ChatRole, FunctionCallBehavior, FunctionCallRequest,
    FunctionDefinition, FunctionSchema, LlmProvider,
};
use crate::error::IoError;
use crate::queries::entity_linker::EntityLinker;
use crate::queries::optimizer::{QueryOptimizer, ResultRanker};
use crate::queries::types::{
    AggregationType, CartridgeType, Explanation, ExecutionHint, ExtractedEntity, FilterOperator,
    LookupType, QueryIntent, QueryOperation, QueryPlan, TraversalDirection,
};
use crate::types::Lsn;
use crate::{Error, Result};
use serde_json::Value;
use std::collections::HashMap;
use std::sync::Arc;
use tokio::sync::RwLock;

/// Configuration for query planner
#[derive(Debug, Clone)]
pub struct QueryPlannerConfig {
    /// Maximum plan complexity
    pub max_plan_complexity: usize,

    /// Enable query caching
    pub enable_caching: bool,

    /// Default ranking threshold
    pub default_rank_threshold: f32,

    /// Max results without explicit limit
    pub max_results_no_limit: usize,
}

impl Default for QueryPlannerConfig {
    fn default() -> Self {
        Self {
            max_plan_complexity: 100,
            enable_caching: true,
            default_rank_threshold: 0.5,
            max_results_no_limit: 1000,
        }
    }
}

/// Natural language query planner
pub struct QueryPlanner {
    /// LLM provider
    llm: Arc<dyn LlmProvider>,

    /// Entity cartridge
    entity_cartridge: Arc<RwLock<EntityCartridge>>,

    /// Topic cartridge
    topic_cartridge: Arc<RwLock<TopicCartridge>>,

    /// Relationship cartridge
    relationship_cartridge: Arc<RwLock<RelationshipCartridge>>,

    /// Entity linker
    entity_linker: Arc<EntityLinker>,

    /// Query optimizer
    optimizer: Arc<QueryOptimizer>,

    /// Configuration
    config: QueryPlannerConfig,
}

impl QueryPlanner {
    /// Create new query planner
    pub fn new(
        llm: Arc<dyn LlmProvider>,
        entity_cartridge: Arc<RwLock<EntityCartridge>>,
        topic_cartridge: Arc<RwLock<TopicCartridge>>,
        relationship_cartridge: Arc<RwLock<RelationshipCartridge>>,
        config: QueryPlannerConfig,
    ) -> Self {
        let optimizer = Arc::new(QueryOptimizer::new(
            entity_cartridge.clone(),
            topic_cartridge.clone(),
            relationship_cartridge.clone(),
        ));

        let entity_linker = Arc::new(EntityLinker::new(
            entity_cartridge.clone(),
            topic_cartridge.clone(),
            Default::default(),
        ));

        Self {
            llm,
            entity_cartridge,
            topic_cartridge,
            relationship_cartridge,
            entity_linker,
            optimizer,
            config,
        }
    }

    /// Translate natural language to query plan
    pub async fn plan(&self, nl_query: &str) -> Result<QueryPlan> {
        // Check cache first
        if self.config.enable_caching {
            if let Some(cached) = self.optimizer.get_cached(nl_query) {
                return Ok(cached);
            }
        }

        // 1. Classify intent
        let intent = self.classify_intent(nl_query).await?;

        // 2. Extract entities from query
        let extracted_entities = self.extract_entities(nl_query).await?;

        // 3. Link entities to cartridges
        let mut entity_links = HashMap::new();
        for entity in &extracted_entities {
            let links = self
                .entity_linker
                .link(&entity.text, entity.entity_type)
                .await?;
            if let Some(best_link) = links.first() {
                entity_links.insert(entity.text.clone(), best_link.entity_id.clone());
            }
        }

        // 4. Generate query operations
        let operations = self.generate_operations(&intent, &entity_links).await?;

        // 5. Optimize plan
        let (operations, hint) = self.optimizer.optimize(operations, &entity_links)?;

        // 6. Estimate cost
        let cost = self.estimate_cost(&operations);

        let plan = QueryPlan {
            intent,
            operations,
            entity_links,
            estimated_cost: cost,
            execution_hint: hint,
        };

        // Cache the plan
        if self.config.enable_caching {
            self.optimizer.cache_plan(nl_query, &plan);
        }

        Ok(plan)
    }

    /// Explain the query plan
    pub async fn explain(&self, nl_query: &str) -> Result<Explanation> {
        let plan = self.plan(nl_query).await?;

        Ok(Explanation {
            original_query: nl_query.to_string(),
            intent: format!("{:?}", plan.intent),
            operations: plan.operations.iter().map(|op| format!("{:?}", op)).collect(),
            entity_links: plan.entity_links.clone(),
            estimated_cost: plan.estimated_cost,
            execution_strategy: format!("{:?}", plan.execution_hint),
            optimization_notes: self.get_optimization_notes(&plan),
        })
    }

    /// Execute query plan and return results
    pub async fn execute(&self, plan: &QueryPlan) -> Result<Vec<Entity>> {
        let mut results = Vec::new();

        for operation in &plan.operations {
            match operation {
                QueryOperation::EntityLookup {
                    cartridge_type,
                    lookup_type,
                    key,
                } => {
                    match cartridge_type {
                        CartridgeType::Entity => {
                            let cartridge = self.entity_cartridge.read().await;
                            let entity = match lookup_type {
                                LookupType::ById => cartridge.get_by_id(key)?.map(|e| e.clone()),
                                LookupType::ByName => {
                                    cartridge.get_by_name(key)?.map(|e| e.clone())
                                }
                                LookupType::ByType => {
                                    let entity_type = EntityType::from_str(key)
                                        .ok_or_else(|| Error::Io(IoError::InternalError(format!("Invalid entity type: {}", key))))?;
                                    cartridge.get_by_type(entity_type)
                                        .ok()
                                        .and_then(|entities| entities.into_iter().next())
                                }
                                _ => None,
                            };

                            if let Some(e) = entity {
                                results.push(e);
                            }
                        }
                        CartridgeType::Topic => {
                            let cartridge = self.topic_cartridge.read().await;
                            if let Some(topic) = cartridge.get_by_name(key)? {
                                // For now, we can't directly convert Topic to Entity
                                // This would require a Topic variant in the Entity enum
                                // For placeholder, skip
                            }
                        }
                        _ => {}
                    }
                }
                QueryOperation::RelationshipTraversal {
                    from_entity,
                    rel_type,
                    direction,
                    max_depth: _,
                } => {
                    let cartridge = self.relationship_cartridge.read().await;

                    match direction {
                        TraversalDirection::Outgoing => {
                            let rels = cartridge.get_from(from_entity)?;
                            for rel in rels {
                                if rel.rel_type == *rel_type {
                                    if let Some(entity) = self
                                        .entity_cartridge
                                        .read()
                                        .await
                                        .get_by_id(&rel.to_entity)?
                                    {
                                        results.push(entity.clone());
                                    }
                                }
                            }
                        }
                        TraversalDirection::Incoming => {
                            let rels = cartridge.get_to(from_entity)?;
                            for rel in rels {
                                if rel.rel_type == *rel_type {
                                    if let Some(entity) = self
                                        .entity_cartridge
                                        .read()
                                        .await
                                        .get_by_id(&rel.from_entity)?
                                    {
                                        results.push(entity.clone());
                                    }
                                }
                            }
                        }
                        TraversalDirection::Both => {
                            let mut outgoing = cartridge.get_from(from_entity)?;
                            let mut incoming = cartridge.get_to(from_entity)?;
                            outgoing.append(&mut incoming);

                            for rel in outgoing {
                                if rel.rel_type == *rel_type {
                                    if let Some(entity) = self
                                        .entity_cartridge
                                        .read()
                                        .await
                                        .get_by_id(&rel.to_entity)?
                                    {
                                        results.push(entity.clone());
                                    }
                                }
                            }
                        }
                    }
                }
                _ => {}
            }
        }

        // Rank results for semantic queries
        if matches!(plan.intent, QueryIntent::SemanticSearch) {
            let ranker = ResultRanker::new(
                self.entity_cartridge.clone(),
                self.topic_cartridge.clone(),
            );

            let ranked = ranker.rank(results, plan)?;
            return Ok(ranked.into_iter().map(|r| r.entity).collect());
        }

        Ok(results)
    }

    /// Query database state at specific LSN (time travel)
    pub async fn query_at_lsn(&self, nl_query: &str, lsn: Lsn) -> Result<QueryPlan> {
        // Parse query normally
        let mut plan = self.plan(nl_query).await?;

        // Add time-travel filter
        plan.operations.insert(
            0,
            QueryOperation::Filter {
                field: "commit_id".to_string(),
                operator: FilterOperator::LessThan,
                value: Value::Number(serde_json::Number::from(lsn.as_u64())),
            },
        );

        // Update intent to time-travel
        plan.intent = QueryIntent::TimeTravel { lsn };

        Ok(plan)
    }

    /// Classify query intent
    async fn classify_intent(&self, query: &str) -> Result<QueryIntent> {
        let function = FunctionDefinition {
            name: "classify_query_intent".to_string(),
            description: "Classify the intent of a database query".to_string(),
            parameters: serde_json::json!({
                "type": "object",
                "properties": {
                    "intent": {
                        "type": "string",
                        "enum": ["point_lookup", "range_scan", "semantic_search", "aggregation", "relationship_traversal", "time_travel", "complex"]
                    },
                    "aggregation_type": {
                        "type": "string",
                        "enum": ["count", "sum", "average", "min", "max"]
                    },
                    "target_entity": {
                        "type": "string",
                        "enum": ["file", "function", "person", "topic", "config"]
                    }
                },
                "required": ["intent"]
            }),
            validate_params: true,
        };

        let request = FunctionCallRequest {
            model: "gpt-4-turbo".to_string(),
            messages: vec![
                ChatMessage {
                    role: ChatRole::System,
                    content: "You are a query classifier. Analyze the user's query and determine its intent.".to_string(),
                },
                ChatMessage {
                    role: ChatRole::User,
                    content: query.to_string(),
                },
            ],
            functions: vec![function],
            function_call: FunctionCallBehavior::Auto,
            temperature: 0.0,
            max_tokens: Some(100),
        };

        let response = self.llm.function_call(request).await
            .map_err(|e| Error::Io(IoError::InternalError(format!("LLM function call failed: {:?}", e))))?;
        self.parse_intent_response(response)
    }

    /// Extract entities from query
    async fn extract_entities(&self, query: &str) -> Result<Vec<ExtractedEntity>> {
        let function = FunctionDefinition {
            name: "extract_query_entities".to_string(),
            description: "Extract entity references from a natural language query".to_string(),
            parameters: serde_json::json!({
                "type": "object",
                "properties": {
                    "entities": {
                        "type": "array",
                        "items": {
                            "type": "object",
                            "properties": {
                                "name": {"type": "string"},
                                "type": {"type": "string"},
                                "context": {"type": "string"}
                            },
                            "required": ["name", "type"]
                        }
                    }
                },
                "required": ["entities"]
            }),
            validate_params: true,
        };

        let request = FunctionCallRequest {
            model: "gpt-4-turbo".to_string(),
            messages: vec![
                ChatMessage {
                    role: ChatRole::System,
                    content: "Extract entity references from the query. Entities include people, topics, files, functions, and configs.".to_string(),
                },
                ChatMessage {
                    role: ChatRole::User,
                    content: query.to_string(),
                },
            ],
            functions: vec![function],
            function_call: FunctionCallBehavior::Auto,
            temperature: 0.0,
            max_tokens: Some(200),
        };

        let response = self.llm.function_call(request).await
            .map_err(|e| Error::Io(IoError::InternalError(format!("LLM function call failed: {:?}", e))))?;
        self.parse_entity_response(response, query)
    }

    /// Generate query operations from intent
    async fn generate_operations(
        &self,
        intent: &QueryIntent,
        entity_links: &HashMap<String, String>,
    ) -> Result<Vec<QueryOperation>> {
        match intent {
            QueryIntent::PointLookup => {
                if let Some(entity_id) = entity_links.values().next() {
                    Ok(vec![QueryOperation::EntityLookup {
                        cartridge_type: CartridgeType::Entity,
                        lookup_type: LookupType::ById,
                        key: entity_id.clone(),
                    }])
                } else {
                    Ok(vec![])
                }
            }
            QueryIntent::SemanticSearch => {
                let mut ops = vec![];

                // Look up linked entities
                for entity_id in entity_links.values() {
                    ops.push(QueryOperation::EntityLookup {
                        cartridge_type: CartridgeType::Entity,
                        lookup_type: LookupType::ById,
                        key: entity_id.clone(),
                    });
                }

                // Traverse relationships
                if let Some(from_entity) = entity_links.values().next() {
                    ops.push(QueryOperation::RelationshipTraversal {
                        from_entity: from_entity.clone(),
                        rel_type: crate::cartridges::RelationshipType::RelatedTo,
                        direction: TraversalDirection::Both,
                        max_depth: 2,
                    });
                }

                Ok(ops)
            }
            QueryIntent::Aggregation { agg_type, field } => Ok(vec![QueryOperation::Aggregate {
                agg_type: *agg_type,
                field: field.clone(),
                group_by: None,
            }]),
            _ => Ok(vec![]),
        }
    }

    /// Estimate query cost
    fn estimate_cost(&self, operations: &[QueryOperation]) -> f32 {
        operations
            .iter()
            .map(|op| match op {
                QueryOperation::PointLookup { .. } => 1.0,
                QueryOperation::RangeScan { .. } => 10.0,
                QueryOperation::EntityLookup { .. } => 2.0,
                QueryOperation::RelationshipTraversal { max_depth, .. } => {
                    *max_depth as f32 * 5.0
                }
                QueryOperation::Filter { .. } => 3.0,
                QueryOperation::Aggregate { .. } => 5.0,
                QueryOperation::Sort { .. } => 8.0,
                QueryOperation::Limit { .. } => 0.5,
            })
            .sum()
    }

    /// Get optimization notes
    fn get_optimization_notes(&self, plan: &QueryPlan) -> Vec<String> {
        let mut notes = Vec::new();

        if plan.estimated_cost < 5.0 {
            notes.push("Low-cost query optimized for point lookups".to_string());
        } else if plan.estimated_cost > 50.0 {
            notes.push("High-cost query - consider adding filters".to_string());
        }

        if matches!(plan.execution_hint, ExecutionHint::UseIndex { .. }) {
            notes.push("Using index for efficient lookup".to_string());
        }

        if matches!(plan.execution_hint, ExecutionHint::Parallelize) {
            notes.push("Operations parallelized for faster execution".to_string());
        }

        notes
    }

    /// Parse intent classification response
    fn parse_intent_response(&self, response: crate::llm::FunctionCallResponse) -> Result<QueryIntent> {
        use crate::llm::FunctionCall;

        let function_call = response.function_call
            .ok_or_else(|| Error::Io(IoError::InternalError("No function call in response".to_string())))?;

        let args: serde_json::Value = serde_json::from_str(&function_call.arguments)
            .map_err(|e| Error::Io(IoError::InternalError(format!("Failed to parse arguments: {}", e))))?;

        let intent_str: String = serde_json::from_value(args.get("intent").cloned().unwrap())
            .map_err(|e| Error::Io(IoError::InternalError(format!("Failed to parse intent: {}", e))))?;

        let intent = match intent_str.as_str() {
            "point_lookup" => QueryIntent::PointLookup,
            "range_scan" => QueryIntent::RangeScan,
            "semantic_search" => QueryIntent::SemanticSearch,
            "aggregation" => {
                let agg_val = args.get("aggregation_type")
                    .cloned()
                    .unwrap_or(Value::String("count".to_string()));

                let agg_str: String = serde_json::from_value(agg_val)
                    .unwrap_or_else(|_| "count".to_string());

                let agg_type = match agg_str.as_str() {
                    "count" => AggregationType::Count,
                    "sum" => AggregationType::Sum,
                    "average" => AggregationType::Average,
                    "min" => AggregationType::Min,
                    "max" => AggregationType::Max,
                    _ => AggregationType::Count,
                };

                QueryIntent::Aggregation {
                    agg_type,
                    field: "id".to_string(),
                }
            }
            "relationship_traversal" => QueryIntent::RelationshipTraversal {
                rel_type: crate::cartridges::RelationshipType::RelatedTo,
                direction: TraversalDirection::Both,
            },
            "time_travel" => QueryIntent::TimeTravel { lsn: Lsn::INITIAL },
            "complex" => QueryIntent::Complex { operations: vec![] },
            _ => return Err(Error::Io(IoError::InternalError(format!("Unknown intent: {}", intent_str)))),
        };

        Ok(intent)
    }

    /// Parse entity extraction response
    fn parse_entity_response(
        &self,
        response: crate::llm::FunctionCallResponse,
        _query: &str,
    ) -> Result<Vec<ExtractedEntity>> {
        use crate::llm::FunctionCall;

        let function_call = response.function_call
            .ok_or_else(|| Error::Io(IoError::InternalError("No function call in response".to_string())))?;

        let args: serde_json::Value = serde_json::from_str(&function_call.arguments)
            .map_err(|e| Error::Io(IoError::InternalError(format!("Failed to parse arguments: {}", e))))?;

        let entities_array: Vec<Value> = serde_json::from_value(
            args.get("entities")
                .cloned()
                .unwrap_or(Value::Array(vec![])),
        )
        .map_err(|e| Error::Io(IoError::InternalError(format!("Failed to parse entities: {}", e))))?;

        let mut entities = Vec::new();
        for entity_val in entities_array {
            let text: String = serde_json::from_value(
                entity_val
                    .get("text")
                    .cloned()
                    .unwrap_or(Value::String("".to_string())),
            )
            .map_err(|e| Error::Io(IoError::InternalError(format!("Failed to parse entity text: {}", e))))?;

            let entity_type_str: String = serde_json::from_value(
                entity_val
                    .get("entity_type")
                    .cloned()
                    .unwrap_or(Value::String("topic".to_string())),
            )
            .map_err(|e| {
                Error::Io(IoError::InternalError(format!("Failed to parse entity type: {}", e)))
            })?;

            let confidence: f32 = serde_json::from_value(
                entity_val
                    .get("confidence")
                    .cloned()
                    .unwrap_or(Value::Number(serde_json::Number::from_f64(0.5).unwrap())),
            )
            .map_err(|e| Error::Io(IoError::InternalError(format!("Failed to parse confidence: {}", e))))?;

            let entity_type = EntityType::from_str(&entity_type_str)
                .unwrap_or(EntityType::Topic);

            entities.push(ExtractedEntity {
                text,
                entity_type,
                confidence,
                position: (0, 0),
            });
        }

        Ok(entities)
    }
}

/// Builder helper for function schemas
struct FunctionSchemaBuilder {
    name: String,
    description: String,
    properties: HashMap<String, Value>,
    required: Vec<String>,
}

impl FunctionSchemaBuilder {
    fn new(name: impl Into<String>, description: impl Into<String>) -> Self {
        Self {
            name: name.into(),
            description: description.into(),
            properties: HashMap::new(),
            required: Vec::new(),
        }
    }

    fn add_enum_property(
        mut self,
        name: impl Into<String>,
        description: impl Into<String>,
        values: Vec<Value>,
    ) -> Self {
        let prop = serde_json::json!({
            "type": "string",
            "description": description.into(),
            "enum": values
        });
        self.properties.insert(name.into(), prop);
        self
    }

    fn add_array_property(
        mut self,
        name: impl Into<String>,
        description: impl Into<String>,
        _item_type: &str,
    ) -> Self {
        let prop = serde_json::json!({
            "type": "array",
            "description": description.into(),
            "items": {
                "type": "object"
            }
        });
        self.properties.insert(name.into(), prop);
        self
    }

    fn add_required(mut self, name: impl Into<String>) -> Self {
        self.required.push(name.into());
        self
    }

    fn build(self) -> FunctionSchema {
        FunctionSchema {
            name: self.name,
            description: self.description,
            parameters: crate::llm::function::ParametersSchema {
                schema_type: "object".to_string(),
                properties: self
                    .properties
                    .into_iter()
                    .map(|(k, _v)| {
                        (
                            k,
                            crate::llm::function::PropertySchema {
                                schema_type: "string".to_string(),
                                description: None,
                                enum_values: None,
                                nested: None,
                            },
                        )
                    })
                    .collect(),
                required: self.required,
            },
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::llm::provider::*;

    // Simple mock LLM provider for testing
    struct MockLlmProvider;

    impl MockLlmProvider {
        fn new() -> Self {
            Self
        }
    }

    impl LlmProvider for MockLlmProvider {
        fn default_model(&self) -> String {
            "mock-model".to_string()
        }

        async fn chat_completion(&self, _request: ChatRequest) -> Result<ChatResponse> {
            Ok(ChatResponse {
                message: ChatMessage {
                    role: ChatRole::Assistant,
                    content: "Mock response".to_string(),
                    function_call: None,
                    tool_calls: None,
                },
                usage: TokenUsage {
                    prompt_tokens: 10,
                    completion_tokens: 10,
                    total_tokens: 20,
                },
                model: "mock-model".to_string(),
                finish_reason: None,
            })
        }

        async fn call_function(&self, _request: ChatRequest, _schema: &FunctionSchema) -> Result<ChatResponse> {
            Ok(ChatResponse {
                message: ChatMessage {
                    role: ChatRole::Assistant,
                    content: "".to_string(),
                    function_call: Some(FunctionCall {
                        name: "test_function".to_string(),
                        arguments: serde_json::json!({}),
                    }),
                    tool_calls: None,
                },
                usage: TokenUsage {
                    prompt_tokens: 10,
                    completion_tokens: 10,
                    total_tokens: 20,
                },
                model: "mock-model".to_string(),
                finish_reason: None,
            })
        }

        fn health(&self) -> HealthStatus {
            HealthStatus::Healthy
        }

        fn capabilities(&self) -> ProviderCapabilities {
            ProviderCapabilities {
                supports_functions: true,
                supports_streaming: false,
                max_tokens: 4096,
                supported_models: vec!["mock-model".to_string()],
            }
        }
    }

    #[tokio::test]
    async fn test_query_planner_creation() {
        let llm = Arc::new(MockLlmProvider::new());
        let entity_cartridge = Arc::new(RwLock::new(EntityCartridge::new()));
        let topic_cartridge = Arc::new(RwLock::new(TopicCartridge::new()));
        let relationship_cartridge = Arc::new(RwLock::new(RelationshipCartridge::new()));

        let planner = QueryPlanner::new(
            llm,
            entity_cartridge,
            topic_cartridge,
            relationship_cartridge,
            QueryPlannerConfig::default(),
        );

        assert_eq!(planner.config.max_plan_complexity, 100);
    }

    #[tokio::test]
    async fn test_estimate_cost() {
        let llm = Arc::new(MockLlmProvider::new());
        let entity_cartridge = Arc::new(RwLock::new(EntityCartridge::new()));
        let topic_cartridge = Arc::new(RwLock::new(TopicCartridge::new()));
        let relationship_cartridge = Arc::new(RwLock::new(RelationshipCartridge::new()));

        let planner = QueryPlanner::new(
            llm,
            entity_cartridge,
            topic_cartridge,
            relationship_cartridge,
            QueryPlannerConfig::default(),
        );

        let ops = vec![
            QueryOperation::PointLookup {
                key: b"test".to_vec(),
            },
            QueryOperation::Filter {
                field: "id".to_string(),
                operator: FilterOperator::Equals,
                value: Value::String("123".to_string()),
            },
        ];

        let cost = planner.estimate_cost(&ops);
        assert!(cost > 0.0);
    }
}
