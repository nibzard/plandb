//! Core type definitions for LLM function calling
//!
//! Provides fundamental types used across all LLM operations
//! following spec/ai_plugins_v1.md

const std = @import("std");

pub const Value = std.json.Value;

/// Error types for LLM operations
pub const LLMError = error{
    // Provider errors
    ProviderUnavailable,
    Timeout,
    QuotaExceeded,
    InvalidResponse,

    // Schema errors
    InvalidFunctionSchema,
    InvalidParameters,
    SchemaValidationFailed,

    // Network errors
    NetworkError,
    HttpError,
    RateLimitError,

    // JSON parsing errors
    JsonParseError,
    InvalidJsonStructure,

    // Configuration errors
    MissingApiKey,
    InvalidConfiguration,
};

/// Function result from LLM provider
pub const FunctionResult = struct {
    function_name: []const u8,
    arguments: Value,
    raw_response: []const u8,
    provider: []const u8,
    model: []const u8,
    tokens_used: ?TokenUsage,

    pub fn deinit(self: *FunctionResult, allocator: std.mem.Allocator) void {
        allocator.free(self.function_name);
        allocator.free(self.raw_response);
        allocator.free(self.provider);
        allocator.free(self.model);
        if (self.tokens_used) |tokens| tokens.deinit(allocator);
    }
};

/// Token usage information
pub const TokenUsage = struct {
    prompt_tokens: u32,
    completion_tokens: u32,
    total_tokens: u32,

    pub fn deinit(self: TokenUsage, allocator: std.mem.Allocator) void {
        _ = allocator;
        _ = self;
    }
};

/// Validation result for function responses
pub const ValidationResult = struct {
    is_valid: bool,
    errors: []const ValidationError,
    warnings: []const ValidationWarning,

    pub fn deinit(self: ValidationResult, allocator: std.mem.Allocator) void {
        for (self.errors) |*err| err.deinit(allocator);
        allocator.free(self.errors);
        for (self.warnings) |*warn| warn.deinit(allocator);
        allocator.free(self.warnings);
    }
};

pub const ValidationError = struct {
    field: []const u8,
    message: []const u8,

    pub fn deinit(self: ValidationError, allocator: std.mem.Allocator) void {
        allocator.free(self.field);
        allocator.free(self.message);
    }
};

pub const ValidationWarning = struct {
    field: []const u8,
    message: []const u8,

    pub fn deinit(self: ValidationWarning, allocator: std.mem.Allocator) void {
        allocator.free(self.field);
        allocator.free(self.message);
    }
};

/// Provider capabilities
pub const ProviderCapabilities = struct {
    max_tokens: u32,
    supports_streaming: bool,
    supports_function_calling: bool,
    supports_parallel_calls: bool,
    max_functions_per_call: u32,
    max_context_length: u32,
};

/// TLS configuration for HTTP clients
pub const TlsConfig = struct {
    /// Enable TLS certificate validation (true for production, false for dev)
    validate_certificates: bool = true,
    /// Path to custom CA bundle (null to use system defaults)
    ca_bundle_path: ?[]const u8 = null,

    pub fn deinit(self: *TlsConfig, allocator: std.mem.Allocator) void {
        if (self.ca_bundle_path) |path| {
            allocator.free(path);
        }
    }
};

/// Generic configuration for any provider
pub const ProviderConfig = struct {
    api_key: []const u8,
    model: []const u8,
    base_url: []const u8,
    timeout_ms: u32 = 30000,
    max_retries: u32 = 3,
    retry_delay_ms: u32 = 1000,
    /// TLS security configuration
    tls: TlsConfig = .{},

    pub fn deinit(self: *ProviderConfig, allocator: std.mem.Allocator) void {
        allocator.free(self.api_key);
        allocator.free(self.model);
        allocator.free(self.base_url);
        self.tls.deinit(allocator);
    }
};

test "token_usage" {
    const usage = TokenUsage{
        .prompt_tokens = 100,
        .completion_tokens = 50,
        .total_tokens = 150,
    };

    try std.testing.expectEqual(@as(u32, 100), usage.prompt_tokens);
    try std.testing.expectEqual(@as(u32, 50), usage.completion_tokens);
    try std.testing.expectEqual(@as(u32, 150), usage.total_tokens);
}

test "provider_capabilities" {
    const caps = ProviderCapabilities{
        .max_tokens = 4096,
        .supports_streaming = true,
        .supports_function_calling = true,
        .supports_parallel_calls = true,
        .max_functions_per_call = 10,
        .max_context_length = 8192,
    };

    try std.testing.expect(caps.supports_function_calling);
    try std.testing.expectEqual(@as(u32, 4096), caps.max_tokens);
}

test "tls_config_default_validation_enabled" {
    const tls = TlsConfig{};
    try std.testing.expect(tls.validate_certificates); // Default: true
    try std.testing.expect(tls.ca_bundle_path == null);
}

test "tls_config_can_disable_validation" {
    const tls = TlsConfig{ .validate_certificates = false };
    try std.testing.expect(!tls.validate_certificates);
}

test "provider_config_with_tls_validation" {
    const config = ProviderConfig{
        .api_key = "test-key",
        .model = "gpt-4",
        .base_url = "https://api.openai.com/v1",
        .tls = .{ .validate_certificates = true },
    };

    try std.testing.expect(config.tls.validate_certificates);
}

test "provider_config_with_tls_validation_disabled" {
    const config = ProviderConfig{
        .api_key = "test-key",
        .model = "gpt-4",
        .base_url = "https://api.openai.com/v1",
        .tls = .{ .validate_certificates = false },
    };

    try std.testing.expect(!config.tls.validate_certificates);
}
