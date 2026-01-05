//! Cloud Storage Retry Logic with Exponential Backoff
//!
//! This module provides retry logic for cloud storage operations using
//! exponential backoff with full jitter to handle transient failures.
//!
//! # Retry Strategy
//!
//! All cloud operations (upload, download, delete, exists, list) are automatically
//! wrapped with retry logic. The retry strategy uses:
//!
//! - **Exponential Backoff**: Delay doubles with each retry attempt
//! - **Full Jitter**: Random delay to prevent thundering herd problems
//! - **Max Delay Caps**: Backoff capped to prevent excessive waits
//! - **Retryable Errors**: Only retry transient errors (network, 5xx, throttling)
//! - **Per-Operation Policies**: Different retry limits based on operation cost
//!
//! # Exponential Backoff Algorithm
//!
//! ```text
//! delay = min(base_delay * 2^attempt, max_delay)
//! actual_delay = random(0, delay)  // Full jitter
//! sleep(actual_delay)
//! ```
//!
//! # Example
//!
//! ```ignore
//! use northstar_core::cloud::retry::{RetryPolicy, with_retry};
//!
//! let policy = RetryPolicy::download();
//! let result = with_retry(|| async {
//!     adapter.download("backup.nbk").await
//! }, &policy).await?;
//! ```

use super::types::CloudError;
use rand::Rng;
use std::time::Duration;
use tokio::time::sleep;

/// Retry policy for cloud storage operations.
///
/// Defines how operations should be retried on transient failures.
#[derive(Debug, Clone)]
pub struct RetryPolicy {
    /// Maximum number of retry attempts (excluding initial attempt).
    pub max_attempts: usize,
    /// Base delay before first retry (exponential backoff starts here).
    pub base_delay: Duration,
    /// Maximum delay cap (exponential backoff won't exceed this).
    pub max_delay: Duration,
    /// Enable full jitter to randomize delays (prevents thundering herd).
    pub jitter: bool,
}

impl RetryPolicy {
    /// Generic retry policy (5 attempts, 100ms base, 10s max).
    ///
    /// Suitable for most cloud operations.
    pub fn default() -> Self {
        Self {
            max_attempts: 5,
            base_delay: Duration::from_millis(100),
            max_delay: Duration::from_secs(10),
            jitter: true,
        }
    }

    /// Upload retry policy (5 attempts, 100ms base, 30s max).
    ///
    /// Higher max_delay for large file uploads. Moderate retry limit
    /// to avoid cascading upload failures.
    pub fn upload() -> Self {
        Self {
            max_attempts: 5,
            base_delay: Duration::from_millis(100),
            max_delay: Duration::from_secs(30),
            jitter: true,
        }
    }

    /// Download retry policy (10 attempts, 100ms base, 30s max).
    ///
    /// Most aggressive retry policy since reads are safe to retry.
    /// Data integrity is critical, so we retry more frequently.
    pub fn download() -> Self {
        Self {
            max_attempts: 10,
            base_delay: Duration::from_millis(100),
            max_delay: Duration::from_secs(30),
            jitter: true,
        }
    }

    /// Delete retry policy (3 attempts, 200ms base, 10s max).
    ///
    /// Conservative retries since deletes are eventually consistent.
    /// Higher base_delay with lower max_attempts to fail fast.
    pub fn delete() -> Self {
        Self {
            max_attempts: 3,
            base_delay: Duration::from_millis(200),
            max_delay: Duration::from_secs(10),
            jitter: true,
        }
    }

    /// Metadata retry policy for exists/list/get_size (5 attempts, 100ms base, 10s max).
    ///
    /// Balanced policy for metadata operations. Moderate retries with fast fail.
    pub fn metadata() -> Self {
        Self {
            max_attempts: 5,
            base_delay: Duration::from_millis(100),
            max_delay: Duration::from_secs(10),
            jitter: true,
        }
    }

    /// Calculate delay for a given retry attempt.
    ///
    /// Uses exponential backoff: `min(base_delay * 2^attempt, max_delay)`
    /// with optional full jitter.
    fn calculate_delay(&self, attempt: usize) -> Duration {
        // Calculate exponential backoff
        let exponential_delay = self.base_delay.saturating_mul(2_u32.pow(attempt as u32));
        let capped_delay = exponential_delay.min(self.max_delay);

        // Apply jitter if enabled
        if self.jitter {
            let mut rng = rand::thread_rng();
            let delay_ms = capped_delay.as_millis() as u64;
            Duration::from_millis(rng.gen_range(0..=delay_ms))
        } else {
            capped_delay
        }
    }
}

impl Default for RetryPolicy {
    fn default() -> Self {
        Self::default()
    }
}

/// Execute an async operation with retry logic.
///
/// # Arguments
///
/// * `operation` - Async operation to execute (returns Result<T, CloudError>)
/// * `policy` - Retry policy configuration
///
/// # Returns
///
/// * `Ok(T)` - Operation succeeded (possibly after retries)
/// * `Err(CloudError)` - Operation failed after all retry attempts
///
/// # Behavior
///
/// 1. Execute operation initially
/// 2. If operation fails with retryable error:
///    - Calculate delay using exponential backoff: `min(base_delay * 2^attempt, max_delay)`
///    - Apply full jitter: `random(0, delay)`
///    - Sleep for calculated delay
///    - Increment attempt counter
///    - Retry operation
/// 3. If operation fails with non-retryable error or max_attempts exceeded: return error
///
/// # Example
///
/// ```ignore
/// use northstar_core::cloud::retry::{RetryPolicy, with_retry};
///
/// let policy = RetryPolicy::download();
/// let result = with_retry(|| async {
///     adapter.download("backup.nbk").await
/// }, &policy).await?;
/// ```
pub async fn with_retry<F, Fut, T>(
    operation: F,
    policy: &RetryPolicy,
) -> Result<T, CloudError>
where
    F: Fn() -> Fut,
    Fut: std::future::Future<Output = Result<T, CloudError>>,
{
    let mut attempt = 0;

    loop {
        // Attempt the operation
        match operation().await {
            Ok(result) => return Ok(result),

            Err(error) if error.is_retryable() && attempt < policy.max_attempts => {
                // Calculate delay with exponential backoff and jitter
                let delay = policy.calculate_delay(attempt);

                // Log retry attempt (could use tracing::info! if available)
                eprintln!(
                    "Cloud operation retry: attempt {}/{}, delay {}ms, error: {}",
                    attempt + 1,
                    policy.max_attempts + 1,
                    delay.as_millis(),
                    error
                );

                // Sleep before retry
                sleep(delay).await;

                attempt += 1;
            }

            Err(error) => {
                // Non-retryable error or max attempts exceeded
                eprintln!(
                    "Cloud operation failed after {}/{} attempts: {}, retryable: {}",
                    attempt + 1,
                    policy.max_attempts + 1,
                    error,
                    error.is_retryable()
                );
                return Err(error);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_default_policy() {
        let policy = RetryPolicy::default();
        assert_eq!(policy.max_attempts, 5);
        assert_eq!(policy.base_delay, Duration::from_millis(100));
        assert_eq!(policy.max_delay, Duration::from_secs(10));
        assert!(policy.jitter);
    }

    #[test]
    fn test_upload_policy() {
        let policy = RetryPolicy::upload();
        assert_eq!(policy.max_attempts, 5);
        assert_eq!(policy.base_delay, Duration::from_millis(100));
        assert_eq!(policy.max_delay, Duration::from_secs(30));
        assert!(policy.jitter);
    }

    #[test]
    fn test_download_policy() {
        let policy = RetryPolicy::download();
        assert_eq!(policy.max_attempts, 10);
        assert_eq!(policy.base_delay, Duration::from_millis(100));
        assert_eq!(policy.max_delay, Duration::from_secs(30));
        assert!(policy.jitter);
    }

    #[test]
    fn test_delete_policy() {
        let policy = RetryPolicy::delete();
        assert_eq!(policy.max_attempts, 3);
        assert_eq!(policy.base_delay, Duration::from_millis(200));
        assert_eq!(policy.max_delay, Duration::from_secs(10));
        assert!(policy.jitter);
    }

    #[test]
    fn test_metadata_policy() {
        let policy = RetryPolicy::metadata();
        assert_eq!(policy.max_attempts, 5);
        assert_eq!(policy.base_delay, Duration::from_millis(100));
        assert_eq!(policy.max_delay, Duration::from_secs(10));
        assert!(policy.jitter);
    }

    #[test]
    fn test_calculate_delay_no_capping() {
        let policy = RetryPolicy {
            max_attempts: 5,
            base_delay: Duration::from_millis(100),
            max_delay: Duration::from_secs(100), // High cap
            jitter: false,
        };

        // Attempt 0: 100ms * 2^0 = 100ms
        assert_eq!(policy.calculate_delay(0), Duration::from_millis(100));

        // Attempt 1: 100ms * 2^1 = 200ms
        assert_eq!(policy.calculate_delay(1), Duration::from_millis(200));

        // Attempt 2: 100ms * 2^2 = 400ms
        assert_eq!(policy.calculate_delay(2), Duration::from_millis(400));

        // Attempt 3: 100ms * 2^3 = 800ms
        assert_eq!(policy.calculate_delay(3), Duration::from_millis(800));
    }

    #[test]
    fn test_calculate_delay_with_capping() {
        let policy = RetryPolicy {
            max_attempts: 5,
            base_delay: Duration::from_millis(100),
            max_delay: Duration::from_millis(500), // Low cap
            jitter: false,
        };

        // Attempt 0: 100ms * 2^0 = 100ms
        assert_eq!(policy.calculate_delay(0), Duration::from_millis(100));

        // Attempt 1: 100ms * 2^1 = 200ms
        assert_eq!(policy.calculate_delay(1), Duration::from_millis(200));

        // Attempt 2: 100ms * 2^2 = 400ms
        assert_eq!(policy.calculate_delay(2), Duration::from_millis(400));

        // Attempt 3: 100ms * 2^3 = 800ms → capped at 500ms
        assert_eq!(policy.calculate_delay(3), Duration::from_millis(500));

        // Attempt 4: 100ms * 2^4 = 1600ms → capped at 500ms
        assert_eq!(policy.calculate_delay(4), Duration::from_millis(500));
    }

    #[test]
    fn test_calculate_delay_with_jitter() {
        let policy = RetryPolicy {
            max_attempts: 5,
            base_delay: Duration::from_millis(100),
            max_delay: Duration::from_secs(100),
            jitter: true,
        };

        // With jitter, delays should be in range [0, expected_delay]
        for attempt in 0..5 {
            let delay = policy.calculate_delay(attempt);
            let expected_delay = Duration::from_millis(100 * 2_u32.pow(attempt as u32) as u64);
            assert!(delay <= expected_delay, "Delay {:?} should be <= {:?}", delay, expected_delay);
        }
    }

    #[test]
    fn test_custom_policy() {
        let policy = RetryPolicy {
            max_attempts: 20,
            base_delay: Duration::from_millis(50),
            max_delay: Duration::from_secs(60),
            jitter: false,
        };

        assert_eq!(policy.max_attempts, 20);
        assert_eq!(policy.base_delay, Duration::from_millis(50));
        assert_eq!(policy.max_delay, Duration::from_secs(60));
        assert!(!policy.jitter);
    }
}
