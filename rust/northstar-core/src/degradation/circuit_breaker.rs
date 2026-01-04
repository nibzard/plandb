//! Circuit breaker implementation for external service protection

use std::sync::atomic::{AtomicU32, AtomicU8, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};
use std::fmt;

/// Current state of the circuit breaker
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CircuitState {
    /// Normal operation, requests pass through
    Closed,
    /// Circuit tripped, requests fail immediately
    Open,
    /// Testing if service recovered, limited requests allowed
    HalfOpen,
}

/// Error returned when circuit is open
#[derive(Debug, Clone)]
pub struct CircuitOpenError {
    /// Time until circuit might close
    pub retry_after: Duration,
}

impl std::error::Error for CircuitOpenError {}

impl fmt::Display for CircuitOpenError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            f,
            "Circuit is open, retry after {:?}",
            self.retry_after
        )
    }
}

/// Circuit breaker pattern for external service calls
#[derive(Debug)]
pub struct CircuitBreaker {
    /// Current circuit state (encoded as u8 for atomic operations)
    state: AtomicU8,
    /// Consecutive failures
    failure_count: AtomicU32,
    /// Consecutive successes (for recovery)
    success_count: AtomicU32,
    /// When last failure occurred
    last_failure_time: Arc<std::sync::RwLock<Option<Instant>>>,
    /// When last success occurred
    last_success_time: Arc<std::sync::RwLock<Option<Instant>>>,
    /// Failures before opening circuit
    open_threshold: u32,
    /// Attempts to make in half-open state
    half_open_attempts: u32,
    /// How long to stay open before trying again
    timeout: Duration,
}

// State encoding for atomic operations
const STATE_CLOSED: u8 = 0;
const STATE_OPEN: u8 = 1;
const STATE_HALF_OPEN: u8 = 2;

impl CircuitBreaker {
    /// Create a new circuit breaker
    pub fn new(open_threshold: u32, half_open_attempts: u32, timeout: Duration) -> Self {
        Self {
            state: AtomicU8::new(STATE_CLOSED),
            failure_count: AtomicU32::new(0),
            success_count: AtomicU32::new(0),
            last_failure_time: Arc::new(std::sync::RwLock::new(None)),
            last_success_time: Arc::new(std::sync::RwLock::new(None)),
            open_threshold,
            half_open_attempts,
            timeout,
        }
    }

    /// Create with default values
    pub fn default_config() -> Self {
        Self::new(5, 3, Duration::from_secs(60))
    }

    /// Get current circuit state
    pub fn state(&self) -> CircuitState {
        match self.state.load(Ordering::Acquire) {
            STATE_CLOSED => CircuitState::Closed,
            STATE_OPEN => CircuitState::Open,
            STATE_HALF_OPEN => CircuitState::HalfOpen,
            _ => CircuitState::Closed,
        }
    }

    /// Set circuit state
    fn set_state(&self, new_state: CircuitState) {
        let encoded = match new_state {
            CircuitState::Closed => STATE_CLOSED,
            CircuitState::Open => STATE_OPEN,
            CircuitState::HalfOpen => STATE_HALF_OPEN,
        };
        self.state.store(encoded, Ordering::Release);
    }

    /// Get failure count
    pub fn failure_count(&self) -> u32 {
        self.failure_count.load(Ordering::Acquire)
    }

    /// Get success count
    pub fn success_count(&self) -> u32 {
        self.success_count.load(Ordering::Acquire)
    }

    /// Check if circuit should transition from Open to HalfOpen
    fn check_open_timeout(&self) -> bool {
        if let Ok(last_failure) = self.last_failure_time.read() {
            if let Some(last) = *last_failure {
                return last.elapsed() >= self.timeout;
            }
        }
        false
    }

    /// Record a successful call
    fn record_success(&self) {
        self.success_count.fetch_add(1, Ordering::AcqRel);
        self.failure_count.store(0, Ordering::Release);

        if let Ok(mut last_success) = self.last_success_time.write() {
            *last_success = Some(Instant::now());
        }
    }

    /// Record a failed call
    fn record_failure(&self) {
        self.failure_count.fetch_add(1, Ordering::AcqRel);
        self.success_count.store(0, Ordering::Release);

        if let Ok(mut last_failure) = self.last_failure_time.write() {
            *last_failure = Some(Instant::now());
        }
    }

    /// Reset the circuit breaker to closed state
    pub fn reset(&self) {
        self.set_state(CircuitState::Closed);
        self.failure_count.store(0, Ordering::Release);
        self.success_count.store(0, Ordering::Release);

        if let Ok(mut last_failure) = self.last_failure_time.write() {
            *last_failure = None;
        }
        if let Ok(mut last_success) = self.last_success_time.write() {
            *last_success = None;
        }
    }

    /// Check if an operation is allowed
    pub fn allow_request(&self) -> Result<(), CircuitOpenError> {
        let current_state = self.state();

        match current_state {
            CircuitState::Closed => Ok(()),
            CircuitState::Open => {
                if self.check_open_timeout() {
                    // Transition to HalfOpen
                    self.set_state(CircuitState::HalfOpen);
                    self.success_count.store(0, Ordering::Release);
                    Ok(())
                } else {
                    // Calculate retry after time
                    if let Ok(last_failure) = self.last_failure_time.read() {
                        if let Some(last) = *last_failure {
                            let elapsed = last.elapsed();
                            let remaining = self.timeout.saturating_sub(elapsed);
                            return Err(CircuitOpenError {
                                retry_after: remaining,
                            });
                        }
                    }
                    Err(CircuitOpenError {
                        retry_after: Duration::from_secs(0),
                    })
                }
            }
            CircuitState::HalfOpen => Ok(()),
        }
    }
}

/// Execute operation through circuit breaker with failure tracking
pub fn circuit_breaker_call<T, E>(
    breaker: Arc<CircuitBreaker>,
    operation: impl FnOnce() -> Result<T, E>,
) -> Result<T, CircuitBreakerError<E>>
where
    E: std::error::Error + Send + Sync + 'static,
{
    // Check if request is allowed
    breaker.allow_request()?;

    // Execute the operation
    match operation() {
        Ok(result) => {
            breaker.record_success();

            // Check if we should transition from HalfOpen to Closed
            if breaker.state() == CircuitState::HalfOpen {
                let successes = breaker.success_count();
                if successes >= breaker.half_open_attempts {
                    breaker.set_state(CircuitState::Closed);
                }
            }

            Ok(result)
        }
        Err(err) => {
            breaker.record_failure();

            // Check if we should trip the circuit
            let failures = breaker.failure_count();
            if failures >= breaker.open_threshold {
                breaker.set_state(CircuitState::Open);
            } else if breaker.state() == CircuitState::HalfOpen {
                // Any failure in HalfOpen opens the circuit
                breaker.set_state(CircuitState::Open);
            }

            Err(CircuitBreakerError::OperationError(err))
        }
    }
}

/// Error type for circuit breaker calls
#[derive(Debug)]
pub enum CircuitBreakerError<E> {
    /// Circuit is open
    CircuitOpen(CircuitOpenError),
    /// Underlying operation failed
    OperationError(E),
}

impl<E: std::error::Error> std::error::Error for CircuitBreakerError<E> {}

impl<E: std::error::Error> fmt::Display for CircuitBreakerError<E> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::CircuitOpen(err) => write!(f, "Circuit open: {}", err),
            Self::OperationError(err) => write!(f, "Operation error: {}", err),
        }
    }
}

impl<E> From<CircuitOpenError> for CircuitBreakerError<E> {
    fn from(err: CircuitOpenError) -> Self {
        Self::CircuitOpen(err)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_circuit_breaker_new() {
        let breaker = CircuitBreaker::new(5, 3, Duration::from_secs(60));
        assert_eq!(breaker.state(), CircuitState::Closed);
        assert_eq!(breaker.failure_count(), 0);
        assert_eq!(breaker.success_count(), 0);
    }

    #[test]
    fn test_circuit_breaker_default_config() {
        let breaker = CircuitBreaker::default_config();
        assert_eq!(breaker.state(), CircuitState::Closed);
        assert_eq!(breaker.open_threshold, 5);
        assert_eq!(breaker.half_open_attempts, 3);
        assert_eq!(breaker.timeout, Duration::from_secs(60));
    }

    #[test]
    fn test_circuit_breaker_allow_request_closed() {
        let breaker = CircuitBreaker::default_config();
        assert!(breaker.allow_request().is_ok());
    }

    #[test]
    fn test_circuit_breaker_trip() {
        let breaker = Arc::new(CircuitBreaker::new(3, 2, Duration::from_secs(1)));

        // Simulate failures
        for _ in 0..3 {
            breaker.record_failure();
        }

        assert_eq!(breaker.state(), CircuitState::Closed);
        assert_eq!(breaker.failure_count(), 3);

        // Next call should trip the circuit
        let result = circuit_breaker_call(Arc::clone(&breaker), || Err::<(), _>(std::io::Error::new(
            std::io::ErrorKind::Other,
            "test error",
        )));

        assert!(result.is_err());
        assert_eq!(breaker.state(), CircuitState::Open);
    }

    #[test]
    fn test_circuit_breaker_recovery() {
        let breaker = Arc::new(CircuitBreaker::new(2, 2, Duration::from_millis(100)));

        // Trip the circuit
        breaker.set_state(CircuitState::Open);
        breaker.record_failure();

        // Should be open
        assert!(matches!(breaker.allow_request(), Err(_)));

        // Wait for timeout
        std::thread::sleep(Duration::from_millis(150));

        // Should allow request now (transition to HalfOpen)
        assert!(breaker.allow_request().is_ok());
        assert_eq!(breaker.state(), CircuitState::HalfOpen);
    }

    #[test]
    fn test_circuit_breaker_half_open_to_closed() {
        let breaker = Arc::new(CircuitBreaker::new(2, 2, Duration::from_millis(100)));

        // Set to HalfOpen
        breaker.set_state(CircuitState::HalfOpen);

        // Simulate successful calls
        for _ in 0..2 {
            let result = circuit_breaker_call(Arc::clone(&breaker), || Ok::<(), std::io::Error>(()));
            assert!(result.is_ok());
        }

        // Should transition to Closed
        assert_eq!(breaker.state(), CircuitState::Closed);
    }

    #[test]
    fn test_circuit_breaker_half_open_failure() {
        let breaker = Arc::new(CircuitBreaker::new(2, 2, Duration::from_millis(100)));

        // Set to HalfOpen
        breaker.set_state(CircuitState::HalfOpen);

        // Simulate failure
        let result = circuit_breaker_call(Arc::clone(&breaker), || Err::<(), _>(std::io::Error::new(
            std::io::ErrorKind::Other,
            "test error",
        )));

        assert!(result.is_err());
        assert_eq!(breaker.state(), CircuitState::Open);
    }

    #[test]
    fn test_circuit_breaker_reset() {
        let breaker = CircuitBreaker::new(2, 2, Duration::from_secs(60));

        // Trip the circuit
        breaker.set_state(CircuitState::Open);
        breaker.record_failure();

        assert_eq!(breaker.failure_count(), 1);

        // Reset
        breaker.reset();

        assert_eq!(breaker.state(), CircuitState::Closed);
        assert_eq!(breaker.failure_count(), 0);
        assert_eq!(breaker.success_count(), 0);
    }

    #[test]
    fn test_circuit_breaker_success_recording() {
        let breaker = CircuitBreaker::default_config();

        breaker.record_success();
        assert_eq!(breaker.success_count(), 1);
        assert_eq!(breaker.failure_count(), 0);

        breaker.record_success();
        assert_eq!(breaker.success_count(), 2);
    }

    #[test]
    fn test_circuit_breaker_failure_recording() {
        let breaker = CircuitBreaker::default_config();

        breaker.record_failure();
        assert_eq!(breaker.failure_count(), 1);
        assert_eq!(breaker.success_count(), 0);

        breaker.record_failure();
        assert_eq!(breaker.failure_count(), 2);
    }
}
