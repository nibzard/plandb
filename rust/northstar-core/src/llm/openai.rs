//! OpenAI API client implementation
//!
//! This module provides an OpenAI-specific implementation of the LLM provider trait,
//! supporting GPT models for chat completions and function calling.

use async_trait::async_trait;
use crate::llm::provider::{
    LlmProvider, ChatRequest, ChatResponse, ChatMessage, ChatRole,
    FunctionCallRequest, FunctionCallResponse, FunctionCall, TokenUsage,
    ProviderCapabilities, HealthStatus, LlmError, Result, RateLimiter,
};
use serde::{Deserialize, Serialize};
use serde_json::json;
use std::sync::Arc;
use std::time::Duration;
use futures::stream::{Stream, StreamExt};
use std::pin::Pin;

/// OpenAI provider configuration
#[derive(Debug, Clone)]
pub struct OpenAIConfig {
    pub api_key: String,
    pub organization_id: Option<String>,
    pub base_url: Option<String>,
    pub default_model: String,
    pub rate_limit: RateLimiterConfig,
    pub retry_config: RetryConfig,
    pub timeout: Duration,
}

#[derive(Debug, Clone)]
pub struct RateLimiterConfig {
    pub requests_per_minute: u32,
    pub tokens_per_minute: u32,
}

#[derive(Debug, Clone)]
pub struct RetryConfig {
    pub max_attempts: u32,
    pub initial_backoff: Duration,
    pub backoff_multiplier: f64,
    pub max_backoff: Duration,
}

impl Default for RetryConfig {
    fn default() -> Self {
        Self {
            max_attempts: 3,
            initial_backoff: Duration::from_millis(100),
            backoff_multiplier: 2.0,
            max_backoff: Duration::from_secs(10),
        }
    }
}

impl OpenAIConfig {
    pub fn default_with_key(api_key: String) -> Self {
        Self {
            api_key,
            organization_id: None,
            base_url: Some("https://api.openai.com/v1".to_string()),
            default_model: "gpt-4-turbo".to_string(),
            rate_limit: RateLimiterConfig {
                requests_per_minute: 3000,
                tokens_per_minute: 200000,
            },
            retry_config: RetryConfig::default(),
            timeout: Duration::from_secs(60),
        }
    }

    pub fn from_env() -> Result<Self> {
        let api_key = std::env::var("OPENAI_API_KEY")
            .map_err(|_| LlmError::InvalidRequest(
                "OPENAI_API_KEY not set".to_string()
            ))?;

        Ok(Self {
            api_key,
            organization_id: std::env::var("OPENAI_ORGANIZATION").ok(),
            base_url: std::env::var("OPENAI_BASE_URL").ok(),
            default_model: std::env::var("OPENAI_DEFAULT_MODEL")
                .unwrap_or_else(|_| "gpt-4-turbo".to_string()),
            rate_limit: RateLimiterConfig {
                requests_per_minute: 3000,
                tokens_per_minute: 200000,
            },
            retry_config: RetryConfig::default(),
            timeout: Duration::from_secs(60),
        })
    }
}

/// OpenAI provider implementation
pub struct OpenAIProvider {
    config: OpenAIConfig,
    #[cfg(feature = "llm-openai")]
    client: reqwest::Client,
    rate_limiter: Arc<RateLimiter>,
}

impl OpenAIProvider {
    pub fn new(config: OpenAIConfig) -> Result<Self> {
        #[cfg(feature = "llm-openai")]
        let client = reqwest::Client::builder()
            .timeout(config.timeout)
            .build()
            .map_err(|e| LlmError::InvalidRequest(format!("Failed to create HTTP client: {}", e)))?;

        #[cfg(not(feature = "llm-openai"))]
        let _ = config; // Suppress unused warning

        let rate_limiter = Arc::new(RateLimiter::new(
            config.rate_limit.requests_per_minute,
            config.rate_limit.tokens_per_minute,
        ));

        #[cfg(feature = "llm-openai")]
        return Ok(Self {
            config,
            client,
            rate_limiter,
        });

        #[cfg(not(feature = "llm-openai"))]
        Err(LlmError::Unsupported(
            "OpenAI provider requires 'llm-openai' feature".to_string()
        ))
    }

    fn base_url(&self) -> &str {
        self.config.base_url
            .as_deref()
            .unwrap_or("https://api.openai.com/v1")
    }

    #[cfg(feature = "llm-openai")]
    async fn make_request<T: serde::de::DeserializeOwned>(
        &self,
        endpoint: &str,
        payload: serde_json::Value,
    ) -> Result<T> {
        // Check rate limits
        self.rate_limiter.check_request()?;

        let url = format!("{}/{}", self.base_url(), endpoint);

        let mut request = self.client
            .post(&url)
            .header("Authorization", format!("Bearer {}", self.config.api_key))
            .json(&payload);

        if let Some(org_id) = &self.config.organization_id {
            request = request.header("OpenAI-Organization", org_id);
        }

        let response = request
            .send()
            .await
            .map_err(|e| LlmError::NetworkError(e.to_string()))?;

        if response.status().is_success() {
            let body = response.text().await
                .map_err(|e| LlmError::NetworkError(e.to_string()))?;

            serde_json::from_str(&body)
                .map_err(|e| LlmError::ParseError(format!("Failed to parse response: {}", e)))
        } else {
            let status = response.status();
            let body = response.text().await
                .unwrap_or_else(|_| "Unable to read error response".to_string());

            Err(parse_openai_error(status, &body))
        }
    }
}

#[cfg(feature = "llm-openai")]
fn parse_openai_error(status: reqwest::StatusCode, body: &str) -> LlmError {
    if let Ok(err) = serde_json::from_str::<OpenAIErrorResponse>(body) {
        match err.error.type_.as_str() {
            "invalid_request_error" => LlmError::InvalidRequest(err.error.message),
            "authentication_error" => LlmError::AuthenticationFailed {
                provider: "openai".to_string(),
            },
            "rate_limit_error" => LlmError::RateLimitExceeded {
                provider: "openai".to_string(),
                retry_after: None,
            },
            _ => LlmError::ProviderError {
                provider: "openai".to_string(),
                code: err.error.type_,
                message: err.error.message,
            },
        }
    } else {
        LlmError::ProviderError {
            provider: "openai".to_string(),
            code: status.as_u16().to_string(),
            message: body.to_string(),
        }
    }
}

#[async_trait]
impl LlmProvider for OpenAIProvider {
    fn name(&self) -> &str {
        "openai"
    }

    async fn chat_completion(&self, request: ChatRequest) -> Result<ChatResponse> {
        #[cfg(feature = "llm-openai")]
        {
            let payload = to_openai_chat_payload(&request);

            let response: OpenAIChatResponse = self.make_request("chat/completions", payload).await?;

            self.rate_limiter.record_request(response.usage.total_tokens);

            Ok(from_openai_chat_response(response))
        }

        #[cfg(not(feature = "llm-openai"))]
        Err(LlmError::Unsupported(
            "OpenAI provider requires 'llm-openai' feature".to_string()
        ))
    }

    async fn chat_completion_stream(
        &self,
        _request: ChatRequest,
    ) -> Result<Pin<Box<dyn Stream<Item = Result<String>> + Send>>> {
        #[cfg(feature = "llm-openai")]
        {
            // For now, return a simple stream
            // Full SSE streaming implementation would go here
            use futures::stream;
            Ok(Box::pin(stream::once(async move {
                Ok("Streaming not fully implemented yet".to_string())
            })))
        }

        #[cfg(not(feature = "llm-openai"))]
        Err(LlmError::Unsupported(
            "OpenAI provider requires 'llm-openai' feature".to_string()
        ))
    }

    async fn function_call(&self, request: FunctionCallRequest) -> Result<FunctionCallResponse> {
        #[cfg(feature = "llm-openai")]
        {
            let payload = to_openai_function_payload(&request);

            let response: OpenAIChatResponse = self.make_request("chat/completions", payload).await?;

            self.rate_limiter.record_request(response.usage.total_tokens);

            Ok(from_openai_function_response(response))
        }

        #[cfg(not(feature = "llm-openai"))]
        Err(LlmError::Unsupported(
            "OpenAI provider requires 'llm-openai' feature".to_string()
        ))
    }

    async fn health_check(&self) -> Result<HealthStatus> {
        #[cfg(feature = "llm-openai")]
        {
            let url = format!("{}/models", self.base_url());

            let response = self.client
                .get(&url)
                .header("Authorization", format!("Bearer {}", self.config.api_key))
                .send()
                .await
                .map_err(|e| LlmError::NetworkError(e.to_string()))?;

            if response.status().is_success() {
                Ok(HealthStatus::Healthy)
            } else {
                Ok(HealthStatus::Degraded)
            }
        }

        #[cfg(not(feature = "llm-openai"))]
        Err(LlmError::Unsupported(
            "OpenAI provider requires 'llm-openai' feature".to_string()
        ))
    }

    fn capabilities(&self) -> ProviderCapabilities {
        ProviderCapabilities {
            supports_function_calling: true,
            supports_streaming: true,
            supports_vision: true,
            max_tokens: 128000,
            max_functions: 128,
        }
    }
}

// OpenAI API types

#[derive(Debug, Serialize, Deserialize)]
struct OpenAIChatRequest {
    model: String,
    messages: Vec<OpenAIMessage>,
    temperature: f32,
    max_tokens: Option<u32>,
    top_p: f32,
    stop: Option<Vec<String>>,
    functions: Option<Vec<OpenAIFunction>>,
    function_call: Option<OpenAIFunctionCall>,
}

#[derive(Debug, Serialize, Deserialize)]
struct OpenAIMessage {
    role: String,
    content: String,
    function_call: Option<OpenAIFunctionCallData>,
}

#[derive(Debug, Serialize, Deserialize)]
struct OpenAIFunctionCallData {
    name: String,
    arguments: String,
}

#[derive(Debug, Serialize, Deserialize)]
struct OpenAIFunction {
    name: String,
    description: String,
    parameters: serde_json::Value,
}

#[derive(Debug, Serialize, Deserialize)]
#[serde(untagged)]
enum OpenAIFunctionCall {
    Auto { auto: bool },
    Function { name: String },
    None,
}

#[derive(Debug, Serialize, Deserialize)]
struct OpenAIChatResponse {
    id: String,
    object: String,
    created: u64,
    model: String,
    choices: Vec<OpenAIChoice>,
    usage: OpenAIUsage,
}

#[derive(Debug, Serialize, Deserialize)]
struct OpenAIChoice {
    index: u32,
    message: OpenAIMessage,
    finish_reason: String,
}

#[derive(Debug, Serialize, Deserialize)]
struct OpenAIUsage {
    prompt_tokens: u32,
    completion_tokens: u32,
    total_tokens: u32,
}

#[derive(Debug, Serialize, Deserialize)]
struct OpenAIErrorResponse {
    error: OpenAIErrorDetail,
}

#[derive(Debug, Serialize, Deserialize)]
struct OpenAIErrorDetail {
    message: String,
    #[serde(rename = "type")]
    type_: String,
    code: Option<String>,
}

// Conversion functions

#[cfg(feature = "llm-openai")]
fn to_openai_chat_payload(request: &ChatRequest) -> serde_json::Value {
    json!({
        "model": request.model,
        "messages": request.messages.iter().map(|m| {
            json!({
                "role": format!("{:?}", m.role).to_lowercase(),
                "content": m.content,
            })
        }).collect::<Vec<_>>(),
        "temperature": request.temperature,
        "max_tokens": request.max_tokens,
        "top_p": request.top_p,
        "stop": request.stop,
    })
}

#[cfg(feature = "llm-openai")]
fn to_openai_function_payload(request: &FunctionCallRequest) -> serde_json::Value {
    json!({
        "model": request.model,
        "messages": request.messages.iter().map(|m| {
            json!({
                "role": format!("{:?}", m.role).to_lowercase(),
                "content": m.content,
            })
        }).collect::<Vec<_>>(),
        "functions": request.functions.iter().map(|f| {
            json!({
                "name": f.name,
                "description": f.description,
                "parameters": f.parameters,
            })
        }).collect::<Vec<_>>(),
        "function_call": match request.function_call {
            super::FunctionCallBehavior::Auto => serde_json::json!({"auto": true}),
            super::FunctionCallBehavior::MustCall(ref name) => {
                serde_json::json!({"name": name})
            }
            super::FunctionCallBehavior::None => serde_json::json!("none"),
        },
        "temperature": request.temperature,
        "max_tokens": request.max_tokens,
    })
}

#[cfg(feature = "llm-openai")]
fn from_openai_chat_response(response: OpenAIChatResponse) -> ChatResponse {
    let choice = response.choices.first().unwrap();
    let message = ChatMessage {
        role: match choice.message.role.as_str() {
            "system" => ChatRole::System,
            "user" => ChatRole::User,
            "assistant" => ChatRole::Assistant,
            "tool" => ChatRole::Tool,
            _ => ChatRole::Assistant,
        },
        content: choice.message.content.clone(),
    };

    ChatResponse {
        message,
        usage: TokenUsage {
            prompt_tokens: response.usage.prompt_tokens,
            completion_tokens: response.usage.completion_tokens,
            total_tokens: response.usage.total_tokens,
        },
        finish_reason: choice.finish_reason.clone(),
        metadata: {
            let mut meta = std::collections::HashMap::new();
            meta.insert("id".to_string(), serde_json::json!(response.id));
            meta.insert("model".to_string(), serde_json::json!(response.model));
            meta
        },
    }
}

#[cfg(feature = "llm-openai")]
fn from_openai_function_response(response: OpenAIChatResponse) -> FunctionCallResponse {
    let choice = response.choices.first().unwrap();

    let function_call = choice.message.function_call.as_ref().map(|fc| {
        FunctionCall {
            name: fc.name.clone(),
            arguments: fc.arguments.clone(),
            parsed_arguments: None, // Would parse if validate_params enabled
        }
    });

    let message = if function_call.is_none() {
        Some(ChatMessage {
            role: ChatRole::Assistant,
            content: choice.message.content.clone(),
        })
    } else {
        None
    };

    FunctionCallResponse {
        function_call,
        message,
        usage: TokenUsage {
            prompt_tokens: response.usage.prompt_tokens,
            completion_tokens: response.usage.completion_tokens,
            total_tokens: response.usage.total_tokens,
        },
        finish_reason: choice.finish_reason.clone(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_openai_config_with_key() {
        let config = OpenAIConfig::default_with_key("sk-test".to_string());
        assert_eq!(config.api_key, "sk-test");
        assert_eq!(config.default_model, "gpt-4-turbo");
    }
}
