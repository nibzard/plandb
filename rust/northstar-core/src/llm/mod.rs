//! LLM Provider Interface
//!
//! This module provides a provider-agnostic interface for integrating Large Language Models
//! into NorthstarDB. It supports multiple providers (OpenAI, Anthropic, local models)
//! through a unified API with chat completions, streaming, and function calling.
//!
//! # Architecture
//!
//! The module is organized into:
//! - **provider**: Core trait and types for LLM providers
//! - **openai**: OpenAI API client implementation
//! - **anthropic**: Anthropic API client implementation
//! - **local**: Local model (e.g., Ollama) interface
//! - **function**: Function calling schema system
//!
//! # Example
//!
//! ```rust,no_run
//! use northstar_core::llm::{LlmClientFactory, ChatRequest, ChatMessage, ChatRole};
//!
//! #[tokio::main]
//! async fn main() -> northstar_core::Result<()> {
//!     let provider = LlmClientFactory::from_env("openai")?;
//!
//!     let request = ChatRequest {
//!         model: "gpt-4-turbo".to_string(),
//!         messages: vec![
//!             ChatMessage {
//!                 role: ChatRole::User,
//!                 content: "What is a B+tree?".to_string(),
//!             },
//!         ],
//!         temperature: 0.7,
//!         max_tokens: Some(1000),
//!         top_p: 1.0,
//!         stop: None,
//!         extra_params: Default::default(),
//!     };
//!
//!     let response = provider.chat_completion(request).await?;
//!     println!("{}", response.message.content);
//!
//!     Ok(())
//! }
//! ```

#[cfg(feature = "llm-openai")]
pub mod openai;

#[cfg(feature = "llm-anthropic")]
pub mod anthropic;

#[cfg(feature = "llm-local")]
pub mod local;

pub mod function;
pub mod provider;

// Re-exports for convenience
pub use provider::{
    LlmProvider, ChatRequest, ChatResponse, ChatMessage, ChatRole,
    FunctionCallRequest, FunctionCallResponse, FunctionDefinition,
    FunctionCallBehavior, FunctionCall, TokenUsage,
    ProviderCapabilities, HealthStatus, LlmError, Result,
    LlmClientFactory, FallbackProvider,
};

pub use function::{FunctionSchema, FunctionSchemaBuilder, ParametersSchema, PropertySchema};
