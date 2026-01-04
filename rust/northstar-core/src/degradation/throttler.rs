//! Rate limiting implementation for operation throttling

use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

/// Rate limiter for operation throttling under load
#[derive(Debug)]
pub struct Throttler {
    /// Operations per second limit (0 = no limit)
    rate_limit: u64,
    /// Allowed burst capacity
    burst_size: u64,
    /// Available tokens (decreases on operation, refills over time)
    current_tokens: Mutex<f64>,
    /// When tokens were last refilled
    last_refill: Mutex<Instant>,
    /// Total rejected operations
    rejected_count: AtomicU64,
    /// Total accepted operations
    accepted_count: AtomicU64,
}

impl Throttler {
    /// Create a new throttler
    pub fn new(rate_limit: u64, burst_size: u64) -> Self {
        let actual_burst = if rate_limit > 0 {
            burst_size.min(rate_limit)
        } else {
            burst_size
        };

        Self {
            rate_limit,
            burst_size: actual_burst,
            current_tokens: Mutex::new(actual_burst as f64),
            last_refill: Mutex::new(Instant::now()),
            rejected_count: AtomicU64::new(0),
            accepted_count: AtomicU64::new(0),
        }
    }

    /// Create a throttler with no limit
    pub fn unbounded() -> Self {
        Self {
            rate_limit: 0,
            burst_size: u64::MAX,
            current_tokens: Mutex::new(f64::INFINITY),
            last_refill: Mutex::new(Instant::now()),
            rejected_count: AtomicU64::new(0),
            accepted_count: AtomicU64::new(0),
        }
    }

    /// Get the rate limit
    pub fn rate_limit(&self) -> u64 {
        self.rate_limit
    }

    /// Get the burst size
    pub fn burst_size(&self) -> u64 {
        self.burst_size
    }

    /// Get the number of rejected operations
    pub fn rejected_count(&self) -> u64 {
        self.rejected_count.load(Ordering::Acquire)
    }

    /// Get the number of accepted operations
    pub fn accepted_count(&self) -> u64 {
        self.accepted_count.load(Ordering::Acquire)
    }

    /// Get total operations attempted
    pub fn total_count(&self) -> u64 {
        self.rejected_count() + self.accepted_count()
    }

    /// Refill tokens based on elapsed time
    fn refill_tokens(&self) {
        let mut last_refill = self.last_refill.lock().unwrap();
        let elapsed = last_refill.elapsed();
        *last_refill = Instant::now();
        drop(last_refill);

        if self.rate_limit == 0 {
            return; // No limit
        }

        let tokens_to_add = elapsed.as_secs_f64() * self.rate_limit as f64;
        let mut current_tokens = self.current_tokens.lock().unwrap();

        *current_tokens = (*current_tokens + tokens_to_add).min(self.burst_size as f64);
    }

    /// Reset the throttler (clear all counters)
    pub fn reset(&self) {
        *self.current_tokens.lock().unwrap() = self.burst_size as f64;
        *self.last_refill.lock().unwrap() = Instant::now();
        self.rejected_count.store(0, Ordering::Release);
        self.accepted_count.store(0, Ordering::Release);
    }

    /// Get current token count (for testing/monitoring)
    pub fn current_tokens(&self) -> f64 {
        self.refill_tokens();
        *self.current_tokens.lock().unwrap()
    }

    /// Check if an operation would be allowed without consuming tokens
    pub fn would_allow(&self, cost: u64) -> bool {
        if self.rate_limit == 0 {
            return true;
        }

        self.refill_tokens();
        let current_tokens = *self.current_tokens.lock().unwrap();
        current_tokens >= cost as f64
    }
}

/// Attempt to acquire tokens for operation
pub fn throttler_acquire(throttler: Arc<Throttler>, cost: u64) -> bool {
    if throttler.rate_limit == 0 {
        throttler.accepted_count.fetch_add(1, Ordering::AcqRel);
        return true;
    }

    throttler.refill_tokens();

    let mut current_tokens = throttler.current_tokens.lock().unwrap();

    if *current_tokens >= cost as f64 {
        *current_tokens -= cost as f64;
        drop(current_tokens);
        throttler.accepted_count.fetch_add(1, Ordering::AcqRel);
        true
    } else {
        drop(current_tokens);
        throttler.rejected_count.fetch_add(1, Ordering::AcqRel);
        false
    }
}

/// Attempt to acquire tokens, waiting if necessary
pub fn throttler_acquire_blocking(throttler: Arc<Throttler>, cost: u64, timeout: Duration) -> bool {
    let start = Instant::now();

    while start.elapsed() < timeout {
        if throttler_acquire(Arc::clone(&throttler), cost) {
            return true;
        }

        // Calculate wait time based on refill rate
        if throttler.rate_limit > 0 {
            let wait_time = Duration::from_secs_f64(cost as f64 / throttler.rate_limit as f64);
            std::thread::park_timeout(wait_time.min(Duration::from_millis(100)));
        } else {
            return true;
        }
    }

    false
}

/// Reserve tokens for an operation (advanced API)
pub fn throttler_reserve(throttler: Arc<Throttler>, cost: u64) -> Option<ThrottleReservation> {
    if throttler.rate_limit == 0 {
        throttler.accepted_count.fetch_add(1, Ordering::AcqRel);
        return Some(ThrottleReservation {
            throttler,
            cost,
            valid: true,
        });
    }

    throttler.refill_tokens();

    let mut current_tokens = throttler.current_tokens.lock().unwrap();

    if *current_tokens >= cost as f64 {
        *current_tokens -= cost as f64;
        drop(current_tokens);
        throttler.accepted_count.fetch_add(1, Ordering::AcqRel);
        Some(ThrottleReservation {
            throttler,
            cost,
            valid: true,
        })
    } else {
        drop(current_tokens);
        None
    }
}

/// Represents a reserved throttling operation
pub struct ThrottleReservation {
    throttler: Arc<Throttler>,
    cost: u64,
    valid: bool,
}

impl ThrottleReservation {
    /// Consume the reservation (mark as used)
    pub fn consume(mut self) {
        self.valid = false;
    }

    /// Cancel the reservation (return tokens)
    pub fn cancel(mut self) {
        if self.valid {
            if self.throttler.rate_limit > 0 {
                let mut tokens = self.throttler.current_tokens.lock().unwrap();
                *tokens = (*tokens + self.cost as f64).min(self.throttler.burst_size as f64);
            }
            self.throttler.accepted_count.fetch_sub(1, Ordering::AcqRel);
            self.valid = false;
        }
    }
}

impl Drop for ThrottleReservation {
    fn drop(&mut self) {
        if self.valid {
            // Auto-cancel on drop if not consumed
            if self.throttler.rate_limit > 0 {
                if let Ok(mut tokens) = self.throttler.current_tokens.try_lock() {
                    *tokens = (*tokens + self.cost as f64).min(self.throttler.burst_size as f64);
                }
            }
            self.throttler.accepted_count.fetch_sub(1, Ordering::AcqRel);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::thread;

    #[test]
    fn test_throttler_new() {
        let throttler = Throttler::new(100, 10);
        assert_eq!(throttler.rate_limit(), 100);
        assert_eq!(throttler.burst_size(), 10);
    }

    #[test]
    fn test_throttler_unbounded() {
        let throttler = Throttler::unbounded();
        assert_eq!(throttler.rate_limit(), 0);
        assert!(throttler.would_allow(1000));
    }

    #[test]
    fn test_throttler_acquire() {
        let throttler = Arc::new(Throttler::new(10, 10));

        // Should accept first 10 operations
        for _ in 0..10 {
            assert!(throttler_acquire(Arc::clone(&throttler), 1));
        }

        // Next should be rejected
        assert!(!throttler_acquire(Arc::clone(&throttler), 1));

        assert_eq!(throttler.accepted_count(), 10);
        assert_eq!(throttler.rejected_count(), 1);
    }

    #[test]
    fn test_throttler_refill() {
        let throttler = Arc::new(Throttler::new(100, 10));

        // Exhaust tokens
        for _ in 0..10 {
            throttler_acquire(Arc::clone(&throttler), 1);
        }

        assert!(!throttler_acquire(Arc::clone(&throttler), 1));

        // Wait for refill (100 ops/sec = 10ms per token)
        thread::sleep(Duration::from_millis(20));

        // Should have some tokens now
        assert!(throttler_acquire(Arc::clone(&throttler), 1));
    }

    #[test]
    fn test_throttler_burst() {
        let throttler = Arc::new(Throttler::new(1, 10));

        // Should allow burst of 10 immediately
        for _ in 0..10 {
            assert!(throttler_acquire(Arc::clone(&throttler), 1));
        }

        // Next should be rejected
        assert!(!throttler_acquire(Arc::clone(&throttler), 1));
    }

    #[test]
    fn test_throttler_reset() {
        let throttler = Arc::new(Throttler::new(10, 10));

        // Exhaust tokens
        for _ in 0..10 {
            throttler_acquire(Arc::clone(&throttler), 1);
        }

        assert_eq!(throttler.accepted_count(), 10);

        throttler.reset();

        assert_eq!(throttler.accepted_count(), 0);
        assert_eq!(throttler.rejected_count(), 0);
        assert!(throttler.would_allow(1));
    }

    #[test]
    fn test_throttler_current_tokens() {
        let throttler = Throttler::new(10, 10);

        let tokens = throttler.current_tokens();
        assert!(tokens >= 0.0);
        assert!(tokens <= 10.0);
    }

    #[test]
    fn test_throttler_would_allow() {
        let throttler = Arc::new(Throttler::new(10, 10));

        assert!(throttler.would_allow(5));
        assert!(throttler.would_allow(10));
        assert!(!throttler.would_allow(11));
    }

    #[test]
    fn test_throttler_reserve() {
        let throttler = Arc::new(Throttler::new(10, 10));

        let reservation = throttler_reserve(Arc::clone(&throttler), 5);
        assert!(reservation.is_some());

        // Tokens should be reserved
        assert!(throttler.would_allow(5));
        assert!(!throttler.would_allow(6));
    }

    #[test]
    fn test_throttle_reservation_consume() {
        let throttler = Arc::new(Throttler::new(10, 10));

        let reservation = throttler_reserve(Arc::clone(&throttler), 5).unwrap();
        reservation.consume();

        // Tokens should be consumed (not returned)
        assert!(throttler.would_allow(5));
        assert!(!throttler.would_allow(6));
    }

    #[test]
    fn test_throttle_reservation_cancel() {
        let throttler = Arc::new(Throttler::new(10, 10));

        let reservation = throttler_reserve(Arc::clone(&throttler), 5).unwrap();
        reservation.cancel();

        // Tokens should be returned
        assert!(throttler.would_allow(10));
    }

    #[test]
    fn test_throttle_reservation_drop() {
        let throttler = Arc::new(Throttler::new(10, 10));

        {
            let _reservation = throttler_reserve(Arc::clone(&throttler), 5).unwrap();
            // Reservation goes out of scope without consume
        }

        // Tokens should be returned
        assert!(throttler.would_allow(10));
    }

    #[test]
    fn test_throttler_blocking_acquire() {
        let throttler = Arc::new(Throttler::new(100, 10));

        // Exhaust tokens
        for _ in 0..10 {
            throttler_acquire(Arc::clone(&throttler), 1);
        }

        // Blocking acquire should wait and succeed
        let result = throttler_acquire_blocking(Arc::clone(&throttler), 1, Duration::from_millis(50));
        assert!(result);
    }

    #[test]
    fn test_throttler_cost() {
        let throttler = Arc::new(Throttler::new(10, 10));

        // Acquire with higher cost
        assert!(throttler_acquire(Arc::clone(&throttler), 5));
        assert!(throttler_acquire(Arc::clone(&throttler), 5));

        // Should be out of tokens
        assert!(!throttler_acquire(Arc::clone(&throttler), 1));
    }
}
