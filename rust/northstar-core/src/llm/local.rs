//! Local model provider implementation
//!
//! This module provides support for local LLM models (e.g., Ollama, llama.cpp).
//! This enables running LLM-powered features without external API calls.

use async_trait::async_trait;
use crate::llm::provider::{
    LlmProvider, ChatRequest, ChatResponse, ChatMessage, ChatRole,
    FunctionCallRequest, FunctionCallResponse, TokenUsage,
    ProviderCapabilities, HealthStatus, LlmError, Result,
};
use std::time::Duration;
use std::pin::Pin;
use futures::Stream;

/// Local model configuration
#[derive(Debug, Clone)]
pub struct LocalModelConfig {
    pub endpoint: String,
    pub model: String,
    pub timeout: Duration,
    pub context_window: usize,
}

impl Default for LocalModelConfig {
    fn default() -> Self {
        Self {
            endpoint: "http://localhost:11434".to_string(),
            model: "llama2".to_string(),
            timeout: Duration::from_secs(120),
            context_window: 4096,
        }
    }
}

impl LocalModelConfig {
    pub fn from_env() -> Self {
        Self {
            endpoint: std::env::var("OLLAMA_ENDPOINT")
                .unwrap_or_else(|_| "http://localhost:11434".to_string()),
            model: std::env::var("OLLAMA_MODEL")
                .unwrap_or_else(|_| "llama2".to_string()),
            timeout: Duration::from_secs(120),
            context_window: 4096,
        }
    }
}

/// Local model provider (e.g., Ollama)
pub struct LocalModelProvider {
    config: LocalModelConfig,
    #[cfg(feature = "llm-local")]
    client: reqwest::Client,
}

impl LocalModelProvider {
    pub fn new(config: LocalModelConfig) -> Result<Self> {
        #[cfg(feature = "llm-local")]
        let client = reqwest::Client::builder()
            .timeout(config.timeout)
            .build()
            .map_err(|e| LlmError::InvalidRequest(format!("Failed to create HTTP client: {}", e)))?;

        #[cfg(feature = "llm-local")]
        return Ok(Self { config, client });

        #[cfg(not(feature = "llm-local"))]
        Err(LlmError::Unsupported(
            "Local model provider requires 'llm-local' feature".to_string()
        ))
    }

    fn endpoint(&self) -> &str {
        &self.config.endpoint
    }
}

#[async_trait]
impl LlmProvider for LocalModelProvider {
    fn name(&self) -> &str {
        "local"
    }

    async fn chat_completion(&self, request: ChatRequest) -> Result<ChatResponse> {
        #[cfg(feature = "llm-local")]
        {
            // Ollama API endpoint: /api/generate
            // Implementation would go here
            Err(LlmError::Unsupported(
                "Local model chat completion implementation pending".to_string()
            ))
        }

        #[cfg(not(feature = "llm-local"))]
        Err(LlmError::Unsupported(
            "Local model provider requires 'llm-local' feature".to_string()
        ))
    }

    async fn chat_completion_stream(
        &self,
        _request: ChatRequest,
    ) -> Result<Pin<Box<dyn Stream<Item = Result<String>> + Send>>> {
        #[cfg(feature = "llm-local")]
        {
            // Ollama supports streaming
            Err(LlmError::Unsupported(
                "Local model streaming implementation pending".to_string()
            ))
        }

        #[cfg(not(feature = "llm-local"))]
        Err(LlmError::Unsupported(
            "Local model provider requires 'llm-local' feature".to_string()
        ))
    }

    async fn function_call(&self, _request: FunctionCallRequest) -> Result<FunctionCallResponse> {
        #[cfg(feature = "llm-local")]
        {
            // Function calling with local models
            // Requires model with tool use support or custom implementation
            Err(LlmError::Unsupported(
                "Local model function calling not yet supported".to_string()
            ))
        }

        #[cfg(not(feature = "llm-local"))]
        Err(LlmError::Unsupported(
            "Local model provider requires 'llm-local' feature".to_string()
        ))
    }

    async fn health_check(&self) -> Result<HealthStatus> {
        #[cfg(feature = "llm-local")]
        {
            // Check if Ollama is running
            let url = format!("{}/api/tags", self.endpoint());

            let response = self.client
                .get(&url)
                .send()
                .await
                .map_err(|e| LlmError::NetworkError(e.to_string()))?;

            if response.status().is_success() {
                Ok(HealthStatus::Healthy)
            } else {
                Ok(HealthStatus::Unavailable)
            }
        }

        #[cfg(not(feature = "llm-local"))]
        Err(LlmError::Unsupported(
            "Local model provider requires 'llm-local' feature".to_string()
        ))
    }

    fn capabilities(&self) -> ProviderCapabilities {
        ProviderCapabilities {
            supports_function_calling: false, // Most local models don't support this yet
            supports_streaming: true,
            supports_vision: false,
            max_tokens: self.config.context_window as u32,
            max_functions: 0,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_local_model_config_default() {
        let config = LocalModelConfig::default();
        assert_eq!(config.endpoint, "http://localhost:11434");
        assert_eq!(config.model, "llama2");
        assert_eq!(config.context_window, 4096);
    }

    #[test]
    fn test_local_model_capabilities() {
        let config = LocalModelConfig::default();
        let provider = LocalModelProvider::new(config).unwrap();
        let caps = provider.capabilities();

        assert!(!caps.supports_function_calling);
        assert!(caps.supports_streaming);
        assert!(!caps.supports_vision);
        assert_eq!(caps.max_tokens, 4096);
    }
}
