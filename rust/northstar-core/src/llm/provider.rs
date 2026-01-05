//! Core LLM provider trait and types
//!
//! This module defines the provider-agnostic interface for LLM integration,
//! including the `LlmProvider` trait, request/response types, and error handling.

use async_trait::async_trait;
use std::any::Any;
use std::collections::HashMap;
use std::pin::Pin;
use std::sync::Arc;
use std::time::Duration;
use futures::Stream;
use serde::{Deserialize, Serialize};

/// Result type for LLM operations
pub type Result<T> = std::result::Result<T, LlmError>;

/// LLM provider trait - defines interface for all LLM providers
#[async_trait]
pub trait LlmProvider: Send + Sync + AsAny {
    /// Provider name (e.g., "openai", "anthropic", "local")
    fn name(&self) -> &str;

    /// Chat completion (non-streaming)
    async fn chat_completion(&self, request: ChatRequest) -> Result<ChatResponse>;

    /// Chat completion (streaming)
    async fn chat_completion_stream(&self, request: ChatRequest)
        -> Result<Pin<Box<dyn Stream<Item = Result<String>> + Send>>>;

    /// Function call with structured output
    async fn function_call(&self, request: FunctionCallRequest) -> Result<FunctionCallResponse>;

    /// Health check
    async fn health_check(&self) -> Result<HealthStatus>;

    /// Provider capabilities
    fn capabilities(&self) -> ProviderCapabilities;
}

/// Helper trait for downcasting trait objects
pub trait AsAny: Any {
    fn as_any(&self) -> &dyn Any;
    fn as_any_mut(&mut self) -> &mut dyn Any;
}

impl<T: Any> AsAny for T {
    fn as_any(&self) -> &dyn Any { self }
    fn as_any_mut(&mut self) -> &mut dyn Any { self }
}

/// Chat completion request
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ChatRequest {
    /// Model identifier (e.g., "gpt-4-turbo", "claude-3-opus")
    pub model: String,

    /// Conversation messages
    pub messages: Vec<ChatMessage>,

    /// Temperature (0.0 - 2.0)
    #[serde(default = "default_temperature")]
    pub temperature: f32,

    /// Maximum tokens to generate
    pub max_tokens: Option<u32>,

    /// Top-p sampling (0.0 - 1.0)
    #[serde(default = "default_top_p")]
    pub top_p: f32,

    /// Stop sequences
    pub stop: Option<Vec<String>>,

    /// Additional provider-specific parameters
    #[serde(flatten)]
    pub extra_params: HashMap<String, serde_json::Value>,
}

fn default_temperature() -> f32 { 0.7 }
fn default_top_p() -> f32 { 1.0 }

/// Chat message
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ChatMessage {
    pub role: ChatRole,
    pub content: String,
}

/// Chat role
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
pub enum ChatRole {
    #[serde(rename = "system")]
    System,
    #[serde(rename = "user")]
    User,
    #[serde(rename = "assistant")]
    Assistant,
    #[serde(rename = "tool")]
    Tool,
}

/// Chat completion response
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ChatResponse {
    /// Generated message
    pub message: ChatMessage,

    /// Token usage statistics
    pub usage: TokenUsage,

    /// Finish reason (length, stop, etc.)
    pub finish_reason: String,

    /// Provider-specific metadata
    #[serde(flatten)]
    pub metadata: HashMap<String, serde_json::Value>,
}

/// Token usage statistics
#[derive(Debug, Clone, Copy, Serialize, Deserialize)]
pub struct TokenUsage {
    pub prompt_tokens: u32,
    pub completion_tokens: u32,
    pub total_tokens: u32,
}

/// Function call request
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FunctionCallRequest {
    /// Model identifier
    pub model: String,

    /// Conversation messages
    pub messages: Vec<ChatMessage>,

    /// Available functions
    pub functions: Vec<FunctionDefinition>,

    /// Function call behavior
    #[serde(default)]
    pub function_call: FunctionCallBehavior,

    /// Temperature (typically lower for function calling)
    #[serde(default = "default_function_temperature")]
    pub temperature: f32,

    /// Maximum tokens
    pub max_tokens: Option<u32>,
}

fn default_function_temperature() -> f32 { 0.0 }

/// Function call behavior
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum FunctionCallBehavior {
    /// Let model decide whether to call functions
    Auto,

    /// Force function call (specific function)
    MustCall(String),

    /// No function call (chat only)
    None,
}

impl Default for FunctionCallBehavior {
    fn default() -> Self {
        FunctionCallBehavior::Auto
    }
}

/// Function definition
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FunctionDefinition {
    /// Function name
    pub name: String,

    /// Function description
    pub description: String,

    /// Parameter schema (JSON Schema)
    pub parameters: serde_json::Value,

    /// Whether to validate parameters
    #[serde(default)]
    pub validate_params: bool,
}

/// Function call response
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FunctionCallResponse {
    /// The function call made by the model
    pub function_call: Option<FunctionCall>,

    /// Text response (if no function call)
    pub message: Option<ChatMessage>,

    /// Token usage
    pub usage: TokenUsage,

    /// Finish reason
    pub finish_reason: String,
}

/// Function call
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FunctionCall {
    /// Function name
    pub name: String,

    /// Function arguments (JSON string)
    pub arguments: String,

    /// Parsed arguments (if validation enabled)
    #[serde(skip_serializing_if = "Option::is_none")]
    pub parsed_arguments: Option<serde_json::Value>,
}

/// Provider capabilities
#[derive(Debug, Clone, Copy)]
pub struct ProviderCapabilities {
    /// Supports function calling
    pub supports_function_calling: bool,

    /// Supports streaming responses
    pub supports_streaming: bool,

    /// Supports vision/multimodal
    pub supports_vision: bool,

    /// Maximum context window
    pub max_tokens: u32,

    /// Maximum number of functions per request
    pub max_functions: usize,
}

/// Health status
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HealthStatus {
    Healthy,
    Degraded,
    Unavailable,
}

/// LLM error types
#[derive(Debug, Clone, thiserror::Error)]
pub enum LlmError {
    #[error("Invalid request: {0}")]
    InvalidRequest(String),

    #[error("Provider error [{provider}] {code}: {message}")]
    ProviderError {
        provider: String,
        code: String,
        message: String,
    },

    #[error("Rate limit exceeded [{provider}]{retry_after:?}")]
    RateLimitExceeded {
        provider: String,
        retry_after: Option<Duration>,
    },

    #[error("Authentication failed [{provider}]")]
    AuthenticationFailed {
        provider: String,
    },

    #[error("Network error: {0}")]
    NetworkError(String),

    #[error("Timeout [{provider}] after {duration:?}")]
    Timeout {
        provider: String,
        duration: Duration,
    },

    #[error("Function call error [{function}]: {error}")]
    FunctionCallError {
        function: String,
        error: String,
    },

    #[error("Parse error: {0}")]
    ParseError(String),

    #[error("Provider unavailable: {0}")]
    ProviderUnavailable(String),

    #[error("IO error: {0}")]
    Io(String),

    #[error("Unsupported operation: {0}")]
    Unsupported(String),
}

impl From<std::io::Error> for LlmError {
    fn from(err: std::io::Error) -> Self {
        LlmError::Io(err.to_string())
    }
}

/// Rate limiter for API requests
pub struct RateLimiter {
    requests_per_minute: u32,
    tokens_per_minute: u32,
    request_window: std::sync::Mutex<Vec<std::time::Instant>>,
    token_count: std::sync::atomic::AtomicU32,
    last_reset: std::sync::atomic::AtomicU64,
}

impl RateLimiter {
    pub fn new(requests_per_minute: u32, tokens_per_minute: u32) -> Self {
        Self {
            requests_per_minute,
            tokens_per_minute,
            request_window: std::sync::Mutex::new(Vec::new()),
            token_count: std::sync::atomic::AtomicU32::new(0),
            last_reset: std::sync::atomic::AtomicU64::new(
                std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .unwrap()
                    .as_secs()
            ),
        }
    }

    /// Check if request is allowed
    pub fn check_request(&self) -> Result<()> {
        // Check request rate limit
        let mut window = self.request_window.lock().unwrap();
        let now = std::time::Instant::now();

        // Remove requests older than 1 minute
        window.retain(|&t| now.duration_since(t) < Duration::from_secs(60));

        if window.len() >= self.requests_per_minute as usize {
            return Err(LlmError::RateLimitExceeded {
                provider: "unknown".to_string(),
                retry_after: Some(Duration::from_secs(60)),
            });
        }

        // Check token rate limit
        self.reset_token_count_if_needed();
        let current_tokens = self.token_count.load(std::sync::atomic::Ordering::Relaxed);
        if current_tokens >= self.tokens_per_minute {
            return Err(LlmError::RateLimitExceeded {
                provider: "unknown".to_string(),
                retry_after: Some(Duration::from_secs(60)),
            });
        }

        Ok(())
    }

    /// Record request completion
    pub fn record_request(&self, tokens_used: u32) {
        // Add to request window
        let mut window = self.request_window.lock().unwrap();
        window.push(std::time::Instant::now());

        // Add to token count
        self.reset_token_count_if_needed();
        self.token_count.fetch_add(tokens_used, std::sync::atomic::Ordering::Relaxed);
    }

    /// Reset token count if minute has passed
    fn reset_token_count_if_needed(&self) {
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_secs();

        let last_reset = self.last_reset.load(std::sync::atomic::Ordering::Relaxed);
        if now - last_reset >= 60 {
            self.token_count.store(0, std::sync::atomic::Ordering::Relaxed);
            self.last_reset.store(now, std::sync::atomic::Ordering::Relaxed);
        }
    }

    /// Get time until next request allowed
    pub fn wait_time(&self) -> Option<Duration> {
        let window = self.request_window.lock().unwrap();
        if window.len() < self.requests_per_minute as usize {
            return None;
        }

        let oldest = window.first()?;
        let elapsed = std::time::Instant::now().duration_since(*oldest);
        Some(Duration::from_secs(60).saturating_sub(elapsed))
    }
}

/// Retry configuration
#[derive(Debug, Clone)]
pub struct RetryConfig {
    pub max_attempts: u32,
    pub initial_backoff: Duration,
    pub backoff_multiplier: f64,
    pub max_backoff: Duration,
    pub retryable_codes: Vec<String>,
}

impl Default for RetryConfig {
    fn default() -> Self {
        Self {
            max_attempts: 3,
            initial_backoff: Duration::from_millis(100),
            backoff_multiplier: 2.0,
            max_backoff: Duration::from_secs(10),
            retryable_codes: vec![
                "rate_limit_exceeded".to_string(),
                "server_error".to_string(),
                "timeout".to_string(),
            ],
        }
    }
}

/// LLM client factory
pub struct LlmClientFactory;

impl LlmClientFactory {
    #[cfg(feature = "llm-openai")]
    pub fn create_openai(
        config: crate::llm::openai::OpenAIConfig
    ) -> Result<Arc<dyn LlmProvider>> {
        Ok(Arc::new(crate::llm::openai::OpenAIProvider::new(config)?))
    }

    #[cfg(feature = "llm-anthropic")]
    pub fn create_anthropic(
        config: crate::llm::anthropic::AnthropicConfig
    ) -> Result<Arc<dyn LlmProvider>> {
        Ok(Arc::new(crate::llm::anthropic::AnthropicProvider::new(config)?))
    }

    #[cfg(feature = "llm-local")]
    pub fn create_local(
        config: crate::llm::local::LocalModelConfig
    ) -> Result<Arc<dyn LlmProvider>> {
        Ok(Arc::new(crate::llm::local::LocalModelProvider::new(config)?))
    }

    /// Create from environment variables
    pub fn from_env(provider: &str) -> Result<Arc<dyn LlmProvider>> {
        match provider.to_lowercase().as_str() {
            #[cfg(feature = "llm-openai")]
            "openai" => {
                let config = crate::llm::openai::OpenAIConfig::from_env()?;
                Self::create_openai(config)
            },

            #[cfg(feature = "llm-anthropic")]
            "anthropic" => {
                let config = crate::llm::anthropic::AnthropicConfig::from_env()?;
                Self::create_anthropic(config)
            },

            #[cfg(feature = "llm-local")]
            "local" => {
                let config = crate::llm::local::LocalModelConfig::from_env();
                Self::create_local(config)
            },

            _ => Err(LlmError::InvalidRequest(format!(
                "Unknown provider: {}",
                provider
            ))),
        }
    }

    /// Create with automatic fallback chain
    pub fn with_fallback(
        primary: Arc<dyn LlmProvider>,
        fallbacks: Vec<Arc<dyn LlmProvider>>,
    ) -> FallbackProvider {
        FallbackProvider::new(primary, fallbacks)
    }
}

/// Fallback provider that tries multiple providers in sequence
pub struct FallbackProvider {
    primary: Arc<dyn LlmProvider>,
    fallbacks: Vec<Arc<dyn LlmProvider>>,
}

impl FallbackProvider {
    pub fn new(
        primary: Arc<dyn LlmProvider>,
        fallbacks: Vec<Arc<dyn LlmProvider>>,
    ) -> Self {
        Self {
            primary,
            fallbacks,
        }
    }
}

#[async_trait]
impl LlmProvider for FallbackProvider {
    fn name(&self) -> &str {
        "fallback"
    }

    async fn chat_completion(&self, request: ChatRequest) -> Result<ChatResponse> {
        // Try primary
        match self.primary.chat_completion(request.clone()).await {
            Ok(response) => Ok(response),
            Err(e) => {
                tracing::warn!(
                    provider = %self.primary.name(),
                    error = %e,
                    "Primary provider failed, trying fallbacks"
                );

                // Try fallbacks in order
                for fallback in &self.fallbacks {
                    match fallback.chat_completion(request.clone()).await {
                        Ok(response) => {
                            tracing::info!(
                                provider = %fallback.name(),
                                "Fallback provider succeeded"
                            );
                            return Ok(response);
                        }
                        Err(e) => {
                            tracing::warn!(
                                provider = %fallback.name(),
                                error = %e,
                                "Fallback provider failed"
                            );
                            continue;
                        }
                    }
                }

                // All failed
                Err(LlmError::ProviderUnavailable(
                    "All providers failed".to_string()
                ))
            }
        }
    }

    async fn chat_completion_stream(
        &self,
        request: ChatRequest,
    ) -> Result<Pin<Box<dyn Stream<Item = Result<String>> + Send>>> {
        // For streaming, only try primary (streaming fallbacks are complex)
        self.primary.chat_completion_stream(request).await
    }

    async fn function_call(&self, request: FunctionCallRequest) -> Result<FunctionCallResponse> {
        match self.primary.function_call(request.clone()).await {
            Ok(response) => Ok(response),
            Err(e) => {
                tracing::warn!(
                    provider = %self.primary.name(),
                    error = %e,
                    "Primary provider failed for function call, trying fallbacks"
                );

                for fallback in &self.fallbacks {
                    match fallback.function_call(request.clone()).await {
                        Ok(response) => {
                            tracing::info!(
                                provider = %fallback.name(),
                                "Fallback provider succeeded for function call"
                            );
                            return Ok(response);
                        }
                        Err(e) => {
                            tracing::warn!(
                                provider = %fallback.name(),
                                error = %e,
                                "Fallback provider failed for function call"
                            );
                            continue;
                        }
                    }
                }

                Err(LlmError::ProviderUnavailable(
                    "All providers failed for function call".to_string()
                ))
            }
        }
    }

    async fn health_check(&self) -> Result<HealthStatus> {
        // Check all providers
        match self.primary.health_check().await {
            Ok(HealthStatus::Healthy) => return Ok(HealthStatus::Healthy),
            _ => {},
        }

        for fallback in &self.fallbacks {
            if fallback.health_check().await.ok() == Some(HealthStatus::Healthy) {
                return Ok(HealthStatus::Degraded);
            }
        }

        Ok(HealthStatus::Unavailable)
    }

    fn capabilities(&self) -> ProviderCapabilities {
        // Return primary's capabilities
        self.primary.capabilities()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_chat_request_defaults() {
        let request = ChatRequest {
            model: "gpt-4".to_string(),
            messages: vec![],
            temperature: default_temperature(),
            max_tokens: None,
            top_p: default_top_p(),
            stop: None,
            extra_params: HashMap::new(),
        };

        assert_eq!(request.temperature, 0.7);
        assert_eq!(request.top_p, 1.0);
    }

    #[test]
    fn test_rate_limiter() {
        let limiter = RateLimiter::new(2, 1000);

        // Should allow 2 requests
        assert!(limiter.check_request().is_ok());
        limiter.record_request(100);
        assert!(limiter.check_request().is_ok());
        limiter.record_request(100);

        // 3rd should fail (rate limited)
        assert!(limiter.check_request().is_err());
    }

    #[test]
    fn test_function_call_behavior_default() {
        let behavior = FunctionCallBehavior::default();
        matches!(behavior, FunctionCallBehavior::Auto);
    }
}
