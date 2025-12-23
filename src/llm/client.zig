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
            inline else => |*p| p.deinit(allocator),
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
        const openai_config = OpenAIProvider.Config{
            .api_key = try allocator.dupe(u8, config.api_key),
            .model = try allocator.dupe(u8, config.model),
            .base_url = try allocator.dupe(u8, config.base_url),
            .timeout_ms = config.timeout_ms,
            .max_retries = config.max_retries,
        };
        const provider = try OpenAIProvider.init(allocator, openai_config);
        return LLMProvider{ .openai = provider };
    } else if (std.mem.eql(u8, provider_type, "anthropic")) {
        const anthropic_config = AnthropicProvider.Config{
            .api_key = try allocator.dupe(u8, config.api_key),
            .model = try allocator.dupe(u8, config.model),
            .base_url = try allocator.dupe(u8, config.base_url),
            .timeout_ms = config.timeout_ms,
            .max_retries = config.max_retries,
        };
        const provider = try AnthropicProvider.init(allocator, anthropic_config);
        return LLMProvider{ .anthropic = provider };
    } else if (std.mem.eql(u8, provider_type, "local")) {
        const local_config = LocalProvider.Config{
            .base_url = try allocator.dupe(u8, config.base_url),
            .model = try allocator.dupe(u8, config.model),
            .timeout_ms = config.timeout_ms,
        };
        const provider = try LocalProvider.init(allocator, local_config);
        return LLMProvider{ .local = provider };
    } else {
        return error.InvalidProviderType;
    }
}

test "provider_factory_openai" {
    const config = types.ProviderConfig{
        .api_key = "test-key",
        .model = "gpt-4",
        .base_url = "https://api.openai.com/v1",
    };

    const provider = createProvider(
        std.testing.allocator,
        "openai",
        config
    ) catch |err| {
        // Expected to fail without actual API setup
        try std.testing.expect(err == error.NetworkError or err == error.InvalidConfiguration);
        return;
    };
    defer {
        var p = provider;
        p.deinit(std.testing.allocator);
    }

    try std.testing.expect(provider == .openai);
}

test "provider_factory_invalid_type" {
    const config = types.ProviderConfig{
        .api_key = "test-key",
        .model = "gpt-4",
        .base_url = "https://api.openai.com/v1",
    };

    const result = createProvider(
        std.testing.allocator,
        "invalid_provider",
        config
    );

    try std.testing.expectError(error.InvalidProviderType, result);
}

test "provider_name" {
    // Test that name function compiles for each type
    var local_provider = LLMProvider{ .local = undefined };
    var openai_provider = LLMProvider{ .openai = undefined };
    var anthropic_provider = LLMProvider{ .anthropic = undefined };
    _ = local_provider.name();
    try std.testing.expectEqualStrings("local", local_provider.name());
    try std.testing.expectEqualStrings("openai", openai_provider.name());
    try std.testing.expectEqualStrings("anthropic", anthropic_provider.name());
}
