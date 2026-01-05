//! Plan Budgeting and Resource Management
//!
//! This module provides resource budgeting for multi-plan query execution.
//! It controls the allocation of CPU, memory, and execution time across
//! multiple concurrent plan executions to ensure fair resource usage
//! and prevent resource exhaustion.

use crate::{Error, Result};
use std::collections::HashMap;
use std::sync::Arc;
use std::time::{Duration, Instant};
use tokio::sync::{RwLock, Semaphore};

/// Budget allocation for a query execution
#[derive(Debug, Clone)]
pub struct BudgetAllocation {
    /// Maximum execution time
    pub time_budget: Duration,

    /// Maximum memory in bytes
    pub memory_budget: u64,

    /// CPU quota (0-1, fraction of total CPU)
    pub cpu_quota: f64,

    /// I/O quota (operations per second)
    pub io_quota: Option<u64>,

    /// Priority level (0-10, higher = more important)
    pub priority: u8,
}

impl Default for BudgetAllocation {
    fn default() -> Self {
        Self {
            time_budget: Duration::from_secs(30),
            memory_budget: 100 * 1024 * 1024, // 100 MB
            cpu_quota: 0.3,                    // 30% of CPU
            io_quota: None,
            priority: 5,
        }
    }
}

impl BudgetAllocation {
    /// Create allocation with custom parameters
    pub fn new(time_budget: Duration, memory_budget: u64, cpu_quota: f64, priority: u8) -> Self {
        Self {
            time_budget,
            memory_budget,
            cpu_quota: cpu_quota.clamp(0.0, 1.0),
            io_quota: None,
            priority: priority.clamp(0, 10),
        }
    }

    /// Create high-priority allocation
    pub fn high_priority() -> Self {
        Self {
            time_budget: Duration::from_secs(60),
            memory_budget: 500 * 1024 * 1024, // 500 MB
            cpu_quota: 0.8,
            io_quota: None,
            priority: 8,
        }
    }

    /// Create low-priority allocation
    pub fn low_priority() -> Self {
        Self {
            time_budget: Duration::from_secs(10),
            memory_budget: 50 * 1024 * 1024, // 50 MB
            cpu_quota: 0.1,
            io_quota: None,
            priority: 2,
        }
    }

    /// Create interactive allocation (low latency)
    pub fn interactive() -> Self {
        Self {
            time_budget: Duration::from_millis(500),
            memory_budget: 50 * 1024 * 1024,
            cpu_quota: 0.5,
            io_quota: None,
            priority: 7,
        }
    }

    /// Create batch allocation (high throughput)
    pub fn batch() -> Self {
        Self {
            time_budget: Duration::from_secs(120),
            memory_budget: 200 * 1024 * 1024,
            cpu_quota: 0.2,
            io_quota: None,
            priority: 3,
        }
    }
}

/// Resource usage tracking
#[derive(Debug, Clone)]
pub struct ResourceUsage {
    /// Execution time used
    pub time_used: Duration,

    /// Memory used in bytes
    pub memory_used: u64,

    /// CPU time used
    pub cpu_time_used: Duration,

    /// I/O operations performed
    pub io_operations: u64,

    /// Start time
    pub start_time: Instant,

    /// Whether budget was exceeded
    pub exceeded_budget: bool,
}

impl ResourceUsage {
    /// Create new resource usage tracker
    pub fn new() -> Self {
        Self {
            time_used: Duration::ZERO,
            memory_used: 0,
            cpu_time_used: Duration::ZERO,
            io_operations: 0,
            start_time: Instant::now(),
            exceeded_budget: false,
        }
    }

    /// Update elapsed time
    pub fn update_elapsed(&mut self) {
        self.time_used = self.start_time.elapsed();
    }

    /// Check if time budget exceeded
    pub fn exceeded_time_budget(&self, budget: &BudgetAllocation) -> bool {
        self.time_used > budget.time_budget
    }

    /// Check if memory budget exceeded
    pub fn exceeded_memory_budget(&self, budget: &BudgetAllocation) -> bool {
        self.memory_used > budget.memory_budget
    }

    /// Calculate remaining time
    pub fn remaining_time(&self, budget: &BudgetAllocation) -> Duration {
        budget
            .time_budget
            .saturating_sub(self.time_used)
    }

    /// Calculate remaining memory
    pub fn remaining_memory(&self, budget: &BudgetAllocation) -> u64 {
        budget
            .memory_budget
            .saturating_sub(self.memory_used)
    }
}

/// Resource pool for managing allocations
pub struct ResourcePool {
    /// Total memory available
    total_memory: u64,

    /// Total CPU quota available
    total_cpu_quota: f64,

    /// Currently allocated memory
    allocated_memory: Arc<RwLock<u64>>,

    /// Currently allocated CPU quota
    allocated_cpu: Arc<RwLock<f64>>,

    /// Active allocations
    active_allocations: Arc<RwLock<HashMap<String, BudgetAllocation>>>,

    /// Memory semaphore
    memory_semaphore: Arc<Semaphore>,

    /// CPU semaphore
    cpu_semaphore: Arc<Semaphore>,
}

impl ResourcePool {
    /// Create new resource pool
    pub fn new(total_memory: u64, total_cpu_quota: f64) -> Self {
        // Convert memory to "units" for semaphore (1 MB per unit)
        let memory_units = (total_memory / (1024 * 1024)) as usize;
        let cpu_units = (total_cpu_quota * 100.0) as usize;

        Self {
            total_memory,
            total_cpu_quota: total_cpu_quota.clamp(0.0, 1.0),
            allocated_memory: Arc::new(RwLock::new(0)),
            allocated_cpu: Arc::new(RwLock::new(0.0)),
            active_allocations: Arc::new(RwLock::new(HashMap::new())),
            memory_semaphore: Arc::new(Semaphore::new(memory_units)),
            cpu_semaphore: Arc::new(Semaphore::new(cpu_units)),
        }
    }

    /// Create with defaults (8 GB memory, 80% CPU)
    pub fn with_defaults() -> Self {
        Self::new(8 * 1024 * 1024 * 1024, 0.8)
    }

    /// Request budget allocation
    pub async fn request_budget(
        &self,
        query_id: String,
        allocation: BudgetAllocation,
    ) -> Result<BudgetHandle> {
        // Check if we can satisfy this allocation
        let current_memory = *self.allocated_memory.read().await;
        let current_cpu = *self.allocated_cpu.read().await;

        if current_memory + allocation.memory_budget > self.total_memory {
            return Err(Error::Transaction(
                crate::error::TransactionError::Generic("Insufficient memory for allocation".to_string())
            ));
        }

        if current_cpu + allocation.cpu_quota > self.total_cpu_quota {
            return Err(Error::Transaction(
                crate::error::TransactionError::Generic("Insufficient CPU quota for allocation".to_string())
            ));
        }

        // Acquire semaphores
        let memory_units = (allocation.memory_budget / (1024 * 1024)) as usize;
        let cpu_units = (allocation.cpu_quota * 100.0) as usize;

        let memory_permit = self
            .memory_semaphore
            .acquire_many(memory_units as u32)
            .await
            .map_err(|_| Error::Io)?;

        let cpu_permit = self
            .cpu_semaphore
            .acquire_many(cpu_units as u32)
            .await
            .map_err(|_| Error::Io)?;

        // Update allocations
        {
            let mut mem = self.allocated_memory.write().await;
            *mem += allocation.memory_budget;

            let mut cpu = self.allocated_cpu.write().await;
            *cpu += allocation.cpu_quota;
        }

        // Register active allocation
        {
            let mut active = self.active_allocations.write().await;
            active.insert(query_id.clone(), allocation.clone());
        }

        Ok(BudgetHandle {
            query_id,
            allocation,
            pool: self.clone_handle(),
            memory_permit: Some(memory_permit),
            cpu_permit: Some(cpu_permit),
        })
    }

    /// Release budget allocation
    async fn release_budget(&self, query_id: &str, allocation: &BudgetAllocation) {
        // Update allocations
        {
            let mut mem = self.allocated_memory.write().await;
            *mem = mem.saturating_sub(allocation.memory_budget);

            let mut cpu = self.allocated_cpu.write().await;
            *cpu = (cpu - allocation.cpu_quota).max(0.0);
        }

        // Remove from active allocations
        {
            let mut active = self.active_allocations.write().await;
            active.remove(query_id);
        }
    }

    /// Get current utilization
    pub async fn get_utilization(&self) -> ResourceUtilization {
        let allocated_memory = *self.allocated_memory.read().await;
        let allocated_cpu = *self.allocated_cpu.read().await;
        let active_count = self.active_allocations.read().await.len();

        ResourceUtilization {
            memory_utilization: allocated_memory as f64 / self.total_memory as f64,
            cpu_utilization: allocated_cpu / self.total_cpu_quota,
            active_allocations: active_count as u64,
            available_memory: self.total_memory.saturating_sub(allocated_memory),
            available_cpu: self.total_cpu_quota - allocated_cpu,
        }
    }

    /// Get active allocations
    pub async fn get_active_allocations(&self) -> HashMap<String, BudgetAllocation> {
        let active = self.active_allocations.read().await;
        active.clone()
    }

    /// Clone handle for use in BudgetHandle
    fn clone_handle(&self) -> Arc<ResourcePool> {
        // Simplified - would use Arc in real implementation
        Arc::new(Self::new(self.total_memory, self.total_cpu_quota))
    }
}

/// Resource utilization metrics
#[derive(Debug, Clone)]
pub struct ResourceUtilization {
    /// Memory utilization (0-1)
    pub memory_utilization: f64,

    /// CPU utilization (0-1)
    pub cpu_utilization: f64,

    /// Number of active allocations
    pub active_allocations: u64,

    /// Available memory in bytes
    pub available_memory: u64,

    /// Available CPU quota
    pub available_cpu: f64,
}

/// Handle for an active budget allocation
pub struct BudgetHandle {
    /// Query ID
    query_id: String,

    /// Budget allocation
    allocation: BudgetAllocation,

    /// Reference to resource pool
    pool: Arc<ResourcePool>,

    /// Memory permit
    memory_permit: Option<tokio::sync::SemaphorePermit<'static>>,

    /// CPU permit
    cpu_permit: Option<tokio::sync::SemaphorePermit<'static>>,
}

impl BudgetHandle {
    /// Get budget allocation
    pub fn allocation(&self) -> &BudgetAllocation {
        &self.allocation
    }

    /// Get query ID
    pub fn query_id(&self) -> &str {
        &self.query_id
    }

    /// Check if within budget
    pub fn check_budget(&self, usage: &ResourceUsage) -> BudgetStatus {
        let time_status = if usage.exceeded_time_budget(&self.allocation) {
            BudgetCompliance::Exceeded
        } else {
            BudgetCompliance::Within
        };

        let memory_status = if usage.exceeded_memory_budget(&self.allocation) {
            BudgetCompliance::Exceeded
        } else {
            BudgetCompliance::Within
        };

        BudgetStatus {
            time_status,
            memory_status,
            can_continue: time_status == BudgetCompliance::Within
                && memory_status == BudgetCompliance::Within,
        }
    }

    /// Create resource usage tracker
    pub fn create_tracker(&self) -> ResourceUsage {
        ResourceUsage::new()
    }
}

impl Drop for BudgetHandle {
    fn drop(&mut self) {
        // Release permits
        self.memory_permit = None;
        self.cpu_permit = None;

        // Note: In real implementation, we'd use tokio::spawn to release
        // For now, this is a simplified version
    }
}

/// Budget compliance status
#[derive(Debug, Clone, PartialEq)]
pub enum BudgetCompliance {
    /// Within budget
    Within,

    /// Exceeded budget
    Exceeded,

    /// Near budget limit (warning)
    NearLimit,
}

/// Budget status for an execution
#[derive(Debug, Clone)]
pub struct BudgetStatus {
    /// Time budget status
    pub time_status: BudgetCompliance,

    /// Memory budget status
    pub memory_status: BudgetCompliance,

    /// Whether execution can continue
    pub can_continue: bool,
}

/// Plan budget manager
pub struct PlanBudgetManager {
    /// Resource pool
    pool: Arc<ResourcePool>,

    /// Default allocation for unspecified queries
    default_allocation: BudgetAllocation,

    /// Maximum concurrent allocations
    max_concurrent: usize,
}

impl PlanBudgetManager {
    /// Create new budget manager
    pub fn new(pool: Arc<ResourcePool>, default_allocation: BudgetAllocation) -> Self {
        Self {
            pool,
            default_allocation,
            max_concurrent: 10,
        }
    }

    /// Create with defaults
    pub fn with_defaults() -> Self {
        Self::new(
            Arc::new(ResourcePool::with_defaults()),
            BudgetAllocation::default(),
        )
    }

    /// Allocate budget for a query
    pub async fn allocate_budget(
        &self,
        query_id: String,
        priority: Option<u8>,
    ) -> Result<BudgetHandle> {
        let mut allocation = self.default_allocation.clone();

        // Adjust based on priority
        if let Some(p) = priority {
            allocation.priority = p;

            // Scale budget based on priority
            let scale_factor = if p >= 8 {
                2.0  // High priority
            } else if p <= 3 {
                0.5  // Low priority
            } else {
                1.0  // Normal priority
            };

            allocation.time_budget =
                Duration::from_millis((allocation.time_budget.as_millis() as f64 * scale_factor) as u64);
            allocation.memory_budget = (allocation.memory_budget as f64 * scale_factor) as u64;
            allocation.cpu_quota = (allocation.cpu_quota * scale_factor).min(1.0);
        }

        self.pool.request_budget(query_id, allocation).await
    }

    /// Get resource utilization
    pub async fn get_utilization(&self) -> ResourceUtilization {
        self.pool.get_utilization().await
    }

    /// Get active allocations
    pub async fn get_active_allocations(&self) -> HashMap<String, BudgetAllocation> {
        self.pool.get_active_allocations().await
    }

    /// Set maximum concurrent allocations
    pub fn set_max_concurrent(&mut self, max: usize) {
        self.max_concurrent = max.max(1);
    }
}

impl Default for PlanBudgetManager {
    fn default() -> Self {
        Self::with_defaults()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn test_budget_allocation_default() {
        let allocation = BudgetAllocation::default();
        assert_eq!(allocation.time_budget, Duration::from_secs(30));
        assert_eq!(allocation.memory_budget, 100 * 1024 * 1024);
        assert_eq!(allocation.cpu_quota, 0.3);
    }

    #[tokio::test]
    async fn test_budget_allocation_high_priority() {
        let allocation = BudgetAllocation::high_priority();
        assert_eq!(allocation.priority, 8);
        assert_eq!(allocation.time_budget, Duration::from_secs(60));
        assert!(allocation.cpu_quota > 0.5);
    }

    #[tokio::test]
    async fn test_budget_allocation_low_priority() {
        let allocation = BudgetAllocation::low_priority();
        assert_eq!(allocation.priority, 2);
        assert_eq!(allocation.time_budget, Duration::from_secs(10));
    }

    #[tokio::test]
    async fn test_budget_allocation_interactive() {
        let allocation = BudgetAllocation::interactive();
        assert_eq!(allocation.time_budget, Duration::from_millis(500));
        assert_eq!(allocation.priority, 7);
    }

    #[tokio::test]
    async fn test_budget_allocation_batch() {
        let allocation = BudgetAllocation::batch();
        assert_eq!(allocation.time_budget, Duration::from_secs(120));
        assert_eq!(allocation.priority, 3);
    }

    #[tokio::test]
    async fn test_resource_usage_tracking() {
        let mut usage = ResourceUsage::new();
        assert_eq!(usage.time_used, Duration::ZERO);
        assert_eq!(usage.memory_used, 0);

        usage.update_elapsed();
        assert!(usage.time_used > Duration::ZERO);
    }

    #[tokio::test]
    async fn test_resource_pool_creation() {
        let pool = ResourcePool::new(1024 * 1024 * 1024, 0.5);
        assert_eq!(pool.total_memory, 1024 * 1024 * 1024);
        assert_eq!(pool.total_cpu_quota, 0.5);
    }

    #[tokio::test]
    async fn test_resource_pool_defaults() {
        let pool = ResourcePool::with_defaults();
        assert_eq!(pool.total_memory, 8 * 1024 * 1024 * 1024);
        assert_eq!(pool.total_cpu_quota, 0.8);
    }

    #[tokio::test]
    async fn test_budget_manager_creation() {
        let manager = PlanBudgetManager::with_defaults();
        assert_eq!(manager.max_concurrent, 10);
    }

    #[tokio::test]
    async fn test_budget_allocation_request() {
        let pool = Arc::new(ResourcePool::with_defaults());
        let allocation = BudgetAllocation::default();

        let handle = pool
            .request_budget("test_query".to_string(), allocation)
            .await
            .unwrap();

        assert_eq!(handle.query_id(), "test_query");
        assert_eq!(handle.allocation().priority, 5);
    }

    #[tokio::test]
    async fn test_budget_check() {
        let pool = Arc::new(ResourcePool::with_defaults());
        let allocation = BudgetAllocation::default();

        let handle = pool
            .request_budget("test_query".to_string(), allocation)
            .await
            .unwrap();

        let usage = handle.create_tracker();
        let status = handle.check_budget(&usage);

        assert!(status.can_continue);
        assert_eq!(status.time_status, BudgetCompliance::Within);
        assert_eq!(status.memory_status, BudgetCompliance::Within);
    }

    #[tokio::test]
    async fn test_utilization_tracking() {
        let pool = Arc::new(ResourcePool::with_defaults());
        let allocation = BudgetAllocation {
            memory_budget: 100 * 1024 * 1024,
            cpu_quota: 0.1,
            ..Default::default()
        };

        let _handle = pool
            .request_budget("test_query".to_string(), allocation)
            .await
            .unwrap();

        let utilization = pool.get_utilization().await;

        assert!(utilization.memory_utilization > 0.0);
        assert!(utilization.cpu_utilization > 0.0);
        assert_eq!(utilization.active_allocations, 1);
    }

    #[tokio::test]
    async fn test_resource_usage_exceeded() {
        let allocation = BudgetAllocation::default();
        let mut usage = ResourceUsage::new();

        // Should not be exceeded initially
        assert!(!usage.exceeded_time_budget(&allocation));
        assert!(!usage.exceeded_memory_budget(&allocation));

        // Simulate time exceed
        usage.time_used = Duration::from_secs(31);
        assert!(usage.exceeded_time_budget(&allocation));

        // Simulate memory exceed
        usage.memory_used = 101 * 1024 * 1024;
        assert!(usage.exceeded_memory_budget(&allocation));
    }

    #[tokio::test]
    async fn test_remaining_budget() {
        let allocation = BudgetAllocation::default();
        let mut usage = ResourceUsage::new();

        usage.time_used = Duration::from_secs(10);
        usage.memory_used = 50 * 1024 * 1024;

        let remaining_time = usage.remaining_time(&allocation);
        let remaining_memory = usage.remaining_memory(&allocation);

        assert_eq!(remaining_time, Duration::from_secs(20));
        assert_eq!(remaining_memory, 50 * 1024 * 1024);
    }

    #[tokio::test]
    async fn test_budget_manager_allocate() {
        let manager = PlanBudgetManager::with_defaults();

        let handle = manager
            .allocate_budget("test_query".to_string(), Some(7))
            .await
            .unwrap();

        assert_eq!(handle.query_id(), "test_query");
        assert_eq!(handle.allocation().priority, 7);
    }

    #[tokio::test]
    async fn test_active_allocations() {
        let manager = PlanBudgetManager::with_defaults();

        let _handle1 = manager
            .allocate_budget("query1".to_string(), None)
            .await
            .unwrap();

        let _handle2 = manager
            .allocate_budget("query2".to_string(), None)
            .await
            .unwrap();

        let active = manager.get_active_allocations().await;
        assert_eq!(active.len(), 2);
        assert!(active.contains_key("query1"));
        assert!(active.contains_key("query2"));
    }
}
