//! Provider-agnostic LLM client interface for NorthstarDB AI intelligence layer
//!
//! This module provides a unified interface for interacting with different LLM providers
//! (OpenAI, Anthropic, local models) while maintaining deterministic function calling behavior.

const std = @import("std");

pub const types = @import("types.zig");
pub const function = @import("function.zig");

const OpenAIProvider = @import("providers/openai.zig").OpenAIProvider;
const AnthropicProvider = @import("providers/anthropic.zig").AnthropicProvider;
const LocalProvider = @import("providers/local.zig").LocalProvider;

/// Provider-agnostic LLM provider union
pub const LLMProvider = union(enum) {
    openai: OpenAIProvider,
    anthropic: AnthropicProvider,
    local: LocalProvider,

    /// Call a function through the LLM provider
    pub fn call_function(
        provider: *const LLMProvider,
        schema: function.FunctionSchema,
        params: types.Value,
        allocator: std.mem.Allocator
    ) anyerror!types.FunctionResult {
        switch (provider.*) {
            .openai => |*p| return try p.call_function(schema, params, allocator),
            .anthropic => |*p| return try p.call_function(schema, params, allocator),
            .local => |*p| return try p.call_function(schema, params, allocator),
        }
    }

    /// Validate a function response
    pub fn validate_response(
        provider: *const LLMProvider,
        response: types.FunctionResult,
        allocator: std.mem.Allocator
    ) anyerror!types.ValidationResult {
        switch (provider.*) {
            .openai => |*p| return try p.validate_response(response, allocator),
            .anthropic => |*p| return try p.validate_response(response, allocator),
            .local => |*p| return try p.validate_response(response, allocator),
        }
    }

    /// Get provider capabilities
    pub fn get_capabilities(provider: *const LLMProvider) types.ProviderCapabilities {
        return switch (provider.*) {
            .openai => |*p| p.get_capabilities(),
            .anthropic => |*p| p.get_capabilities(),
            .local => |*p| p.get_capabilities(),
        };
    }

    /// Clean up provider resources
    pub fn deinit(provider: *LLMProvider, allocator: std.mem.Allocator) void {
        switch (provider.*) {
            .openai => |*p| p.deinit(allocator),
            .anthropic => |*p| p.deinit(allocator),
            .local => |*p| p.deinit(allocator),
        }
    }

    /// Get provider name
    pub fn name(provider: *const LLMProvider) []const u8 {
        return switch (provider.*) {
            .openai => "openai",
            .anthropic => "anthropic",
            .local => "local",
        };
    }
};

/// Create an LLM provider from configuration
pub fn createProvider(
    allocator: std.mem.Allocator,
    provider_type: []const u8,
    config: types.ProviderConfig
) !LLMProvider {
    if (std.mem.eql(u8, provider_type, "openai")) {
        var openai_config = OpenAIProvider.Config{
            .api_key = try allocator.dupe(u8, config.api_key),
            .model = try allocator.dupe(u8, config.model),
            .base_url = try allocator.dupe(u8, config.base_url),
            .timeout_ms = config.timeout_ms,
            .max_retries = config.max_retries,
        };
        const provider = try OpenAIProvider.init(allocator, openai_config);
        return LLMProvider{ .openai = provider };
    } else if (std.mem.eql(u8, provider_type, "anthropic")) {
        var anthropic_config = AnthropicProvider.Config{
            .api_key = try allocator.dupe(u8, config.api_key),
            .model = try allocator.dupe(u8, config.model),
            .base_url = try allocator.dupe(u8, config.base_url),
            .timeout_ms = config.timeout_ms,
            .max_retries = config.max_retries,
        };
        const provider = try AnthropicProvider.init(allocator, anthropic_config);
        return LLMProvider{ .anthropic = provider };
    } else if (std.mem.eql(u8, provider_type, "local")) {
        var local_config = LocalProvider.Config{
            .model_path = try allocator.dupe(u8, config.api_key), // reuse api_key for path
            .timeout_ms = config.timeout_ms,
        };
        const provider = try LocalProvider.init(allocator, local_config);
        return LLMProvider{ .local = provider };
    } else {
        return error.InvalidProviderType;
    }
}

test "provider_factory_openai" {
    var config = types.ProviderConfig{
        .api_key = "test-key",
        .model = "gpt-4",
        .base_url = "https://api.openai.com/v1",
    };
    defer config.deinit(std.testing.allocator);

    const provider = createProvider(
        std.testing.allocator,
        "openai",
        config
    ) catch |err| {
        // Expected to fail without actual API setup
        try std.testing.expect(err == error.NetworkError or err == error.InvalidConfiguration);
        return;
    };
    defer provider.deinit(std.testing.allocator);

    try std.testing.expect(provider == .openai);
}

test "provider_factory_invalid_type" {
    var config = types.ProviderConfig{
        .api_key = "test-key",
        .model = "gpt-4",
        .base_url = "https://api.openai.com/v1",
    };
    defer config.deinit(std.testing.allocator);

    const result = createProvider(
        std.testing.allocator,
        "invalid_provider",
        config
    );

    try std.testing.expectError(error.InvalidProviderType, result);
}

test "provider_name" {
    // Create mock providers to test name function
    var config = types.ProviderConfig{
        .api_key = "test-key",
        .model = "test-model",
        .base_url = "https://example.com",
    };
    defer config.deinit(std.testing.allocator);

    // Test that name function compiles for each type
    _ = LLMProvider{ .local = undefined }.name();
    try std.testing.expectEqualStrings("local", LLMProvider{ .local = undefined }.name());
    try std.testing.expectEqualStrings("openai", LLMProvider{ .openai = undefined }.name());
    try std.testing.expectEqualStrings("anthropic", LLMProvider{ .anthropic = undefined }.name());
}
