//! Query Optimization and Result Ranking
//!
//! Optimizes query plans by reordering operations, adding execution hints,
//! and ranking results by relevance.

use crate::cartridges::{Entity, EntityCartridge, EntityType, RelationshipCartridge, TopicCartridge};
use crate::llm::LlmProvider;
use crate::queries::{
    CartridgeType, ExecutionHint, FilterOperator, LookupType, QueryOperation, QueryPlan,
    RankedEntity, TraversalDirection,
};
use crate::{Error, Result};
use std::collections::HashMap;
use std::sync::Arc;
use std::time::SystemTime;
use tokio::sync::RwLock;

/// Cached query plan
#[derive(Debug, Clone)]
struct CachedPlan {
    plan: QueryPlan,
    timestamp: SystemTime,
    hit_count: u32,
}

/// Query optimizer
pub struct QueryOptimizer {
    /// Entity cartridge
    entity_cartridge: Arc<RwLock<EntityCartridge>>,

    /// Topic cartridge
    topic_cartridge: Arc<RwLock<TopicCartridge>>,

    /// Relationship cartridge
    relationship_cartridge: Arc<RwLock<RelationshipCartridge>>,

    /// Query cache
    query_cache: Arc<RwLock<HashMap<String, CachedPlan>>>,
}

impl QueryOptimizer {
    /// Create new query optimizer
    pub fn new(
        entity_cartridge: Arc<RwLock<EntityCartridge>>,
        topic_cartridge: Arc<RwLock<TopicCartridge>>,
        relationship_cartridge: Arc<RwLock<RelationshipCartridge>>,
    ) -> Self {
        Self {
            entity_cartridge,
            topic_cartridge,
            relationship_cartridge,
            query_cache: Arc::new(RwLock::new(HashMap::new())),
        }
    }

    /// Optimize query operations
    pub fn optimize(
        &self,
        operations: Vec<QueryOperation>,
        entity_links: &HashMap<String, String>,
    ) -> Result<(Vec<QueryOperation>, ExecutionHint)> {
        let mut ops = operations;

        // 1. Reorder operations (most selective first)
        ops = self.reorder_operations(ops);

        // 2. Add index hints
        let hint = self.generate_hint(&ops, entity_links);

        // 3. Push down filters
        ops = self.push_down_filters(ops);

        // 4. Merge aggregations
        ops = self.merge_aggregations(ops);

        Ok((ops, hint))
    }

    /// Reorder operations by selectivity
    fn reorder_operations(&self, mut ops: Vec<QueryOperation>) -> Vec<QueryOperation> {
        // Sort by selectivity (point lookups first, scans last)
        ops.sort_by(|a, b| {
            let cost_a = self.operation_selectivity(a);
            let cost_b = self.operation_selectivity(b);
            cost_a.partial_cmp(&cost_b).unwrap_or(std::cmp::Ordering::Equal)
        });
        ops
    }

    /// Calculate operation selectivity (lower = more selective)
    fn operation_selectivity(&self, op: &QueryOperation) -> f32 {
        match op {
            QueryOperation::PointLookup { .. } => 1.0, // Most selective
            QueryOperation::EntityLookup { lookup_type, .. } => match lookup_type {
                LookupType::ById => 1.0,
                LookupType::ByName => 2.0,
                LookupType::ByType => 10.0,
                LookupType::ByCommit => 20.0,
                LookupType::ByCategory => 15.0,
                LookupType::ByKeyword => 12.0,
            },
            QueryOperation::Filter { .. } => 5.0,
            QueryOperation::RelationshipTraversal { max_depth, .. } => *max_depth as f32 * 5.0,
            QueryOperation::RangeScan { .. } => 50.0, // Least selective
            QueryOperation::Aggregate { .. } => 8.0,
            QueryOperation::Sort { .. } => 15.0,
            QueryOperation::Limit { .. } => 0.5,
        }
    }

    /// Generate execution hint
    fn generate_hint(
        &self,
        ops: &[QueryOperation],
        entity_links: &HashMap<String, String>,
    ) -> ExecutionHint {
        // Check if we can use indices
        for op in ops {
            if let QueryOperation::EntityLookup { cartridge_type, lookup_type, key } = op {
                match lookup_type {
                    LookupType::ByName => {
                        return ExecutionHint::UseIndex {
                            index_name: "entity:name".to_string(),
                        };
                    }
                    LookupType::ByType => {
                        return ExecutionHint::UseIndex {
                            index_name: format!("entity:type:{}", key),
                        };
                    }
                    LookupType::ByKeyword => {
                        return ExecutionHint::UseIndex {
                            index_name: "topic:keyword".to_string(),
                        };
                    }
                    _ => {}
                }
            }
        }

        // Check for parallelizable operations
        if ops.len() > 2 && self.are_operations_independent(ops) {
            return ExecutionHint::Parallelize;
        }

        ExecutionHint::UseCache
    }

    /// Check if operations can be parallelized
    fn are_operations_independent(&self, ops: &[QueryOperation]) -> bool {
        // Simplified: operations are independent if they don't depend on each other's results
        // Conservative default - assume independent if all are lookups
        ops.iter().all(|op| matches!(op, QueryOperation::EntityLookup { .. } | QueryOperation::PointLookup { .. }))
    }

    /// Push down filters to early in the pipeline
    fn push_down_filters(&self, ops: Vec<QueryOperation>) -> Vec<QueryOperation> {
        let mut filters: Vec<QueryOperation> = Vec::new();
        let mut others: Vec<QueryOperation> = Vec::new();

        for op in ops {
            if matches!(op, QueryOperation::Filter { .. }) {
                filters.push(op);
            } else {
                others.push(op);
            }
        }

        // Combine: filters first, then other operations
        let mut result = filters;
        result.extend(others);
        result
    }

    /// Merge multiple aggregations into one
    fn merge_aggregations(&self, ops: Vec<QueryOperation>) -> Vec<QueryOperation> {
        let mut aggregations: Vec<QueryOperation> = Vec::new();
        let mut others: Vec<QueryOperation> = Vec::new();

        for op in ops {
            if matches!(op, QueryOperation::Aggregate { .. }) {
                aggregations.push(op);
            } else {
                others.push(op);
            }
        }

        // For now, keep them separate (future: combine into multi-aggregation)
        let mut result = others;
        result.extend(aggregations);
        result
    }

    /// Cache query plan for reuse
    pub fn cache_plan(&self, query: &str, plan: &QueryPlan) {
        let mut cache = self.query_cache.blocking_write();
        cache.insert(
            query.to_string(),
            CachedPlan {
                plan: plan.clone(),
                timestamp: SystemTime::now(),
                hit_count: 0,
            },
        );
    }

    /// Get cached plan if available
    pub fn get_cached(&self, query: &str) -> Option<QueryPlan> {
        let mut cache = self.query_cache.blocking_write();
        if let Some(cached) = cache.get_mut(query) {
            cached.hit_count += 1;
            return Some(cached.plan.clone());
        }
        None
    }

    /// Evict stale cache entries
    pub fn evict_stale(&self, max_age: std::time::Duration) {
        let mut cache = self.query_cache.blocking_write();
        let now = SystemTime::now();

        cache.retain(|_, cached| {
            now.duration_since(cached.timestamp)
                .map(|age| age < max_age)
                .unwrap_or(false)
        });
    }

    /// Clear all cached plans
    pub fn clear_cache(&self) {
        let mut cache = self.query_cache.blocking_write();
        cache.clear();
    }
}

/// Result ranker for semantic queries
pub struct ResultRanker {
    /// Entity cartridge
    entity_cartridge: Arc<RwLock<EntityCartridge>>,

    /// Topic cartridge
    topic_cartridge: Arc<RwLock<TopicCartridge>>,
}

impl ResultRanker {
    /// Create new result ranker
    pub fn new(
        entity_cartridge: Arc<RwLock<EntityCartridge>>,
        topic_cartridge: Arc<RwLock<TopicCartridge>>,
    ) -> Self {
        Self {
            entity_cartridge,
            topic_cartridge,
        }
    }

    /// Rank query results by relevance
    pub fn rank(&self, results: Vec<Entity>, query: &QueryPlan) -> Result<Vec<RankedEntity>> {
        let mut ranked: Vec<RankedEntity> = results
            .into_iter()
            .map(|entity| {
                let score = self.calculate_relevance(&entity, query);
                let rank_reason = self.explain_score(&entity, query, score);
                RankedEntity {
                    entity,
                    relevance_score: score,
                    rank_reason,
                }
            })
            .collect();

        ranked.sort_by(|a, b| {
            b.relevance_score
                .partial_cmp(&a.relevance_score)
                .unwrap_or(std::cmp::Ordering::Equal)
        });

        Ok(ranked)
    }

    /// Calculate relevance score for entity
    fn calculate_relevance(&self, entity: &Entity, query: &QueryPlan) -> f32 {
        let mut score = 0.0;

        // 1. Exact match bonus
        if let Some(linked_id) = query.entity_links.values().next() {
            if entity.id() == linked_id {
                score += 1.0;
            }
        }

        // 2. Confidence score from extraction
        score += entity.confidence() * 0.5;

        // 3. Recency bonus (more recent commits = higher score)
        if let Some(commit_id) = entity.commit_id() {
            let recency = self.calculate_recency(commit_id.as_u64());
            score += recency * 0.3;
        }

        // 4. Topic relevance
        if matches!(query.intent, crate::queries::QueryIntent::SemanticSearch) {
            if let Ok(topic_relevance) = self.calculate_topic_relevance(entity, query) {
                score += topic_relevance * 0.4;
            }
        }

        score.min(1.0)
    }

    /// Calculate recency score based on commit ID
    fn calculate_recency(&self, commit_id: u64) -> f32 {
        // Normalize commit ID to 0-1 range (higher = more recent)
        // Simplified: assume commit IDs are monotonically increasing
        1.0 / (1.0 + (1_000_000_u64.saturating_sub(commit_id.min(1_000_000))) as f32 / 100_000.0)
    }

    /// Calculate topic relevance
    fn calculate_topic_relevance(&self, _entity: &Entity, _query: &QueryPlan) -> Result<f32> {
        // Check if entity is related to queried topics
        // Simplified implementation
        Ok(0.5)
    }

    /// Explain ranking score
    fn explain_score(&self, entity: &Entity, query: &QueryPlan, score: f32) -> String {
        let mut reasons = Vec::new();

        if score > 0.8 {
            reasons.push("High confidence match");
        }

        if entity.confidence() > 0.8 {
            reasons.push("High extraction confidence");
        }

        if let Some(commit_id) = entity.commit_id() {
            if self.calculate_recency(commit_id.as_u64()) > 0.5 {
                reasons.push("Recent commit");
            }
        }

        if matches!(query.intent, crate::queries::QueryIntent::SemanticSearch) {
            reasons.push("Semantically relevant");
        }

        if reasons.is_empty() {
            reasons.push("Standard relevance");
        }

        reasons.join(", ")
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::cartridges::FileEntity;

    #[test]
    fn test_operation_selectivity() {
        let cartridge = Arc::new(RwLock::new(EntityCartridge::new()));
        let topic_cartridge = Arc::new(RwLock::new(TopicCartridge::new()));
        let rel_cartridge = Arc::new(RwLock::new(RelationshipCartridge::new()));

        let optimizer = QueryOptimizer::new(cartridge, topic_cartridge, rel_cartridge);

        let point_lookup = QueryOperation::PointLookup {
            key: b"test".to_vec(),
        };
        let range_scan = QueryOperation::RangeScan {
            start: b"a".to_vec(),
            end: b"z".to_vec(),
        };

        assert!(
            optimizer.operation_selectivity(&point_lookup)
                < optimizer.operation_selectivity(&range_scan)
        );
    }

    #[test]
    fn test_reorder_operations() {
        let cartridge = Arc::new(RwLock::new(EntityCartridge::new()));
        let topic_cartridge = Arc::new(RwLock::new(TopicCartridge::new()));
        let rel_cartridge = Arc::new(RwLock::new(RelationshipCartridge::new()));

        let optimizer = QueryOptimizer::new(cartridge, topic_cartridge, rel_cartridge);

        let ops = vec![
            QueryOperation::RangeScan {
                start: b"a".to_vec(),
                end: b"z".to_vec(),
            },
            QueryOperation::PointLookup {
                key: b"test".to_vec(),
            },
        ];

        let reordered = optimizer.reorder_operations(ops);

        // Point lookup should come first
        assert!(matches!(
            reordered[0],
            QueryOperation::PointLookup { .. }
        ));
    }

    #[test]
    fn test_result_ranking() {
        let cartridge = Arc::new(RwLock::new(EntityCartridge::new()));
        let topic_cartridge = Arc::new(RwLock::new(TopicCartridge::new()));

        let ranker = ResultRanker::new(cartridge, topic_cartridge);

        let entity1 = Entity::new(
            "file-1".to_string(),
            EntityType::File,
            "db.zig".to_string(),
            crate::types::TransactionId::new(100),
            0.9,
        );

        let entity2 = Entity::new(
            "file-2".to_string(),
            EntityType::File,
            "btree.zig".to_string(),
            crate::types::TransactionId::new(50),
            0.7,
        );

        let query = QueryPlan {
            intent: crate::queries::QueryIntent::SemanticSearch,
            operations: vec![],
            entity_links: HashMap::new(),
            estimated_cost: 10.0,
            execution_hint: ExecutionHint::UseCache,
        };

        let results = vec![entity1, entity2];
        let ranked = ranker.rank(results, &query).unwrap();

        assert!(!ranked.is_empty());
        assert_eq!(ranked.len(), 2);

        // First result should have higher or equal score
        assert!(ranked[0].relevance_score >= ranked[1].relevance_score);
    }

    #[test]
    fn test_query_cache() {
        let cartridge = Arc::new(RwLock::new(EntityCartridge::new()));
        let topic_cartridge = Arc::new(RwLock::new(TopicCartridge::new()));
        let rel_cartridge = Arc::new(RwLock::new(RelationshipCartridge::new()));

        let optimizer = QueryOptimizer::new(cartridge, topic_cartridge, rel_cartridge);

        let plan = QueryPlan {
            intent: crate::queries::QueryIntent::PointLookup,
            operations: vec![],
            entity_links: HashMap::new(),
            estimated_cost: 1.0,
            execution_hint: ExecutionHint::UseCache,
        };

        // Cache the plan
        optimizer.cache_plan("test query", &plan);

        // Retrieve from cache
        let cached = optimizer.get_cached("test query");
        assert!(cached.is_some());
        assert_eq!(cached.unwrap().estimated_cost, 1.0);

        // Non-existent query
        let not_cached = optimizer.get_cached("non-existent");
        assert!(not_cached.is_none());
    }
}
