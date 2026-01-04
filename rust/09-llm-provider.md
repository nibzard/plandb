# LLM Provider Interface for AI Intelligence Layer

## Purpose

Provider-agnostic LLM client interface supporting OpenAI, Anthropic, and local models. Provides unified function calling with deterministic results, security validation, and comprehensive error handling.

## Types

### LLMProvider (Enum)

**Description**: Union type representing different LLM providers

**Variants**:
- `OpenAI(OpenAIProvider)` - OpenAI API client
- `Anthropic(AnthropicProvider)` - Anthropic Claude API client
- `Local(LocalProvider)` - Local model client (e.g., Ollama, llama.cpp)

**Invariants**: Exactly one variant is active

### ProviderConfig

**Description**: Generic configuration for any LLM provider

**Fields**:
- `api_key: String` - API authentication key (optional for local)
- `model: String` - Model identifier
- `base_url: String` - API endpoint URL
- `timeout_ms: u32` - Request timeout in milliseconds (default 30000)
- `max_retries: u32` - Maximum retry attempts (default 3)
- `retry_delay_ms: u32` - Delay between retries (default 1000)
- `tls: TlsConfig` - TLS security configuration

**Validation**:
- `base_url` must use HTTPS (except localhost for development)
- Private IP ranges blocked (SSRF protection)
- `api_key` required for cloud providers

### TlsConfig

**Description**: TLS configuration for HTTP clients

**Fields**:
- `validate_certificates: bool` - Enable certificate validation (default true)
- `ca_bundle_path: Option<String>` - Custom CA bundle path (default system)

**Security Warning**: Disabling validation is a security risk, never use in production

### ProviderCapabilities

**Description**: Describes what a provider supports

**Fields**:
- `max_tokens: u32` - Maximum tokens per request
- `supports_streaming: bool` - Streaming responses supported
- `supports_function_calling: bool` - Function calling supported
- `supports_parallel_calls: bool` - Multiple functions per request
- `max_functions_per_call: u32` - Maximum functions in single request
- `max_context_length: u32` - Maximum context window size

### FunctionResult

**Description**: Result from LLM function call

**Fields**:
- `function_name: String` - Name of function called
- `arguments: serde_json::Value` - Function arguments as JSON
- `raw_response: String` - Raw response from provider
- `provider: String` - Provider name
- `model: String` - Model used
- `tokens_used: Option<TokenUsage>` - Token usage statistics

### TokenUsage

**Description**: Token consumption statistics

**Fields**:
- `prompt_tokens: u32` - Tokens in prompt
- `completion_tokens: u32` - Tokens in response
- `total_tokens: u32` - Total tokens used

**Invariants**: `total_tokens == prompt_tokens + completion_tokens`

### ValidationResult

**Description**: Result of validating function response

**Fields**:
- `is_valid: bool` - Response passed validation
- `errors: Vec<ValidationError>` - Validation errors
- `warnings: Vec<ValidationWarning>` - Validation warnings

### ValidationError

**Description**: Validation error with context

**Fields**:
- `field: String` - Field that failed validation
- `message: String` - Error message

### ValidationWarning

**Description**: Non-critical validation issue

**Fields**:
- `field: String` - Field with warning
- `message: String` - Warning message

## Provider-Specific Types

### OpenAIProvider

**Description**: OpenAI API client implementation

**Config Fields**:
- `api_key: String` - OpenAI API key
- `model: String` - Model name (e.g., "gpt-4", "gpt-3.5-turbo")
- `base_url: String` - API base URL (default "https://api.openai.com/v1")
- `timeout_ms: u32` - Request timeout
- `max_retries: u32` - Maximum retries
- `tls: TlsConfig` - TLS settings

### AnthropicProvider

**Description**: Anthropic Claude API client

**Config Fields**:
- `api_key: String` - Anthropic API key
- `model: String` - Model name (e.g., "claude-3-opus-20240229")
- `base_url: String` - API base URL (default "https://api.anthropic.com/v1")
- `timeout_ms: u32` - Request timeout
- `max_retries: u32` - Maximum retries
- `tls: TlsConfig` - TLS settings

### LocalProvider

**Description**: Local model client (Ollama, llama.cpp, etc.)

**Config Fields**:
- `base_url: String` - Local server URL (e.g., "http://localhost:11434")
- `model: String` - Model name
- `timeout_ms: u32` - Request timeout
- `tls: TlsConfig` - TLS settings (may be disabled for localhost)

## Functions

### create_provider(provider_type: &str, config: ProviderConfig) -> Result<LLMProvider, Error>

**Purpose**: Factory function to create provider instance

**Algorithm**:
1. Validate `config.base_url` for security
2. Log warning if HTTPS with disabled TLS validation
3. Match `provider_type` to variant:
   - "openai" -> create OpenAIProvider
   - "anthropic" -> create AnthropicProvider
   - "local" -> create LocalProvider
4. Return provider instance

**Error Conditions**:
- `Error::InvalidProviderType`: Unknown provider type
- `Error::HttpNotAllowed`: HTTP (not HTTPS) URL for cloud provider
- `Error::InvalidUrlScheme`: URL doesn't use http:// or https://
- `Error::PrivateAddressNotAllowed`: URL points to private IP (SSRF protection)

### validate_endpoint_url(url: &str) -> Result<(), Error>

**Purpose**: Security validation for endpoint URLs

**Algorithm**:
1. Check URL starts with "https://" or "http://localhost"
2. Reject "http://" for non-localhost (HTTP not allowed)
3. Check for blocked IP patterns:
   - 127.0.0.1, localhost (allowed for development)
   - 0.0.0.0, ::1 (allowed for development)
   - 169.254.* (link-local)
   - 10.* (private Class A)
   - 192.168.* (private Class C)
   - 172.16.* - 172.31.* (private Class B)
4. Return error if blocked pattern found

**Error Conditions**:
- `Error::HttpNotAllowed`: HTTP without localhost
- `Error::InvalidUrlScheme`: Not http:// or https://
- `Error::PrivateAddressNotAllowed`: Private IP address

### LLMProvider::call_function(&self, schema: FunctionSchema, params: Value) -> Result<FunctionResult, Error>

**Purpose**: Execute function call through LLM

**Algorithm** (delegated to provider implementation):
1. Construct request with function schema and parameters
2. Send HTTP request to provider endpoint
3. Parse response JSON
4. Extract function name and arguments
5. Return FunctionResult

**Error Conditions**:
- `Error::ProviderUnavailable`: Provider not responding
- `Error::Timeout`: Request exceeded timeout
- `Error::QuotaExceeded`: Rate limit or quota exceeded
- `Error::InvalidResponse`: Malformed response
- `Error::NetworkError`: Network failure
- `Error::HttpError`: HTTP error status

### LLMProvider::validate_response(&self, response: FunctionResult) -> Result<ValidationResult, Error>

**Purpose**: Validate function response against schema

**Algorithm**:
1. Parse response arguments
2. Validate against function schema
3. Collect errors and warnings
4. Return validation result

### LLMProvider::get_capabilities(&self) -> ProviderCapabilities

**Purpose**: Get provider capabilities

**Returns**: Static capabilities based on provider type

### LLMProvider::name(&self) -> &str

**Purpose**: Get provider name

**Returns**: "openai", "anthropic", or "local"

### LLMProvider::deinit(&mut self)

**Purpose**: Clean up provider resources

**Algorithm**: Deallocate any stored strings and close connections

## HTTP Client Requirements

Each provider implementation needs an HTTP client with:

1. **TLS support**: Validating certificates by default
2. **Timeout enforcement**: Per-request timeout
3. **Retry logic**: Configurable retries with exponential backoff
4. **Header management**: Authorization headers, content-type
5. **Request body**: JSON serialization

## Dependencies

- **Uses**: Function schema types
- **Used by**: Plugin manager, function calling system

## Rust Implementation Guidance

### Module Structure

```
northstar-ai/llm/
  mod.rs          - Public API, create_provider
  provider.rs     - LLMProvider enum
  openai.rs       - OpenAIProvider implementation
  anthropic.rs    - AnthropicProvider implementation
  local.rs        - LocalProvider implementation
  types.rs        - Common types
```

### Type Definitions

- **LLMProvider**: Use `enum LLMProvider { OpenAI(...), Anthropic(...), Local(...) }`
- **Value**: Use `serde_json::Value` for JSON values
- **FunctionResult**: Struct with owned String fields

### Concurrency

- **LLMProvider**: Can be `Send + Sync` if HTTP client is
- Use `reqwest::Client` for thread-safe HTTP operations
- Consider `Arc<LLMProvider>` for shared instances

### Key Decisions

- **HTTP client**: Use `reqwest` for async, `ureq` for sync
- **JSON**: Use `serde_json` for serialization
- **TLS**: Use `rustls` or `native-tls` via reqwest
- **Retries**: Implement exponential backoff with `tokio::time::sleep`

### Implementation Notes

1. Implement `Drop` for each provider to cleanup resources
2. Use `thiserror` for error types
3. Add request IDs for tracing
4. Log requests/responses at debug level (without sensitive data)

### Testing Strategy

**Unit tests for**:
- URL validation (SSRF protection)
- Provider factory creates correct variant
- Capability queries return correct values

**Integration tests** (with mock server):
- Function call request/response
- Error handling (timeout, network error)
- Retry logic

**Property tests for**:
- Token usage sums correctly
