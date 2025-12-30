//! Local model provider implementation for LLM function calling
//!
//! Implements support for local LLM servers like Ollama, LM Studio, etc.
//! Following spec/ai_plugins_v1.md.

const std = @import("std");
const types = @import("../types.zig");
const function = @import("../function.zig");

pub const LocalProvider = struct {
    allocator: std.mem.Allocator,
    base_url: []const u8,
    model: []const u8,
    timeout_ms: u32,
    http_client: std.http.Client,
    tls_config: TlsConfig,

    const Self = @This();

    pub const TlsConfig = struct {
        validate_certificates: bool = true,
    };

    pub const Config = struct {
        base_url: []const u8 = "http://localhost:11434",
        model: []const u8 = "llama3.2",
        timeout_ms: u32 = 120000, // Local models may be slower
        tls: TlsConfig = .{},
    };

    pub fn init(allocator: std.mem.Allocator, config: Config) !Self {
        return Self{
            .allocator = allocator,
            .base_url = try allocator.dupe(u8, config.base_url),
            .model = try allocator.dupe(u8, config.model),
            .timeout_ms = config.timeout_ms,
            .http_client = std.http.Client{ .allocator = allocator },
            .tls_config = config.tls,
        };
    }

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        self.http_client.deinit();
        allocator.free(self.base_url);
        allocator.free(self.model);
    }

    pub fn get_capabilities(_: *const Self) types.ProviderCapabilities {
        return .{
            .max_tokens = 4096,
            .supports_streaming = false,
            .supports_function_calling = true,
            .supports_parallel_calls = false,
            .max_functions_per_call = 1,
            .max_context_length = 32768,
        };
    }

    pub fn call_function(
        self: *const Self,
        schema: function.FunctionSchema,
        params: types.Value,
        allocator: std.mem.Allocator
    ) !types.FunctionResult {
        _ = params;

        const local_tool = try self.convertToLocalTool(&schema, allocator);
        defer {
            if (local_tool == .object) {
                var it = local_tool.object.iterator();
                while (it.next()) |entry| {
                    allocator.free(entry.key_ptr.*);
                }
                local_tool.object.deinit();
            }
        }

        const payload = try self.buildToolCallPayload(local_tool, allocator);
        defer {
            if (payload == .object) {
                var it = payload.object.iterator();
                while (it.next()) |entry| {
                    allocator.free(entry.key_ptr.*);
                }
                payload.object.deinit();
            }
        }

        const response_body = try self.makeApiCall("/api/chat", payload, allocator);
        defer allocator.free(response_body);

        return try self.parseToolResponse(response_body, allocator);
    }

    pub fn validate_response(
        self: *const Self,
        response: types.FunctionResult,
        allocator: std.mem.Allocator
    ) !types.ValidationResult {
        _ = self;

        var errors = std.ArrayList(types.ValidationError).initCapacity(allocator, 0) catch return error.OutOfMemory;
        var warnings = std.ArrayList(types.ValidationWarning).initCapacity(allocator, 0) catch return error.OutOfMemory;

        if (response.function_name.len == 0) {
            try errors.append(allocator, .{
                .field = try allocator.dupe(u8, "function_name"),
                .message = try allocator.dupe(u8, "Function name is empty"),
            });
        }

        if (response.arguments != .object) {
            try errors.append(allocator, .{
                .field = try allocator.dupe(u8, "arguments"),
                .message = try allocator.dupe(u8, "Arguments must be a JSON object"),
            });
        }

        return types.ValidationResult{
            .is_valid = errors.items.len == 0,
            .errors = try errors.toOwnedSlice(allocator),
            .warnings = try warnings.toOwnedSlice(allocator),
        };
    }

    pub fn chat(
        self: *const Self,
        messages: []const ChatMessage,
        tools: ?[]const function.FunctionSchema,
        allocator: std.mem.Allocator
    ) !ChatResponse {
        const payload = try self.buildChatPayload(messages, tools, allocator);
        defer {
            if (payload == .object) {
                var it = payload.object.iterator();
                while (it.next()) |entry| {
                    allocator.free(entry.key_ptr.*);
                }
                payload.object.deinit();
            }
        }

        const response_body = try self.makeApiCall("/api/chat", payload, allocator);
        defer allocator.free(response_body);

        return try self.parseChatResponse(response_body, allocator);
    }

    pub const ChatMessage = struct {
        role: []const u8,
        content: []const u8,
    };

    pub const ChatResponse = struct {
        model: []const u8,
        created_at: []const u8,
        message: Message,
        done: bool,
        usage: ?TokenUsage,
        tool_calls: ?[]const ToolCall,

        pub fn deinit(self: *ChatResponse, allocator: std.mem.Allocator) void {
            allocator.free(self.model);
            allocator.free(self.created_at);
            self.message.deinit(allocator);
            if (self.usage) |*u| u.deinit(allocator);
            if (self.tool_calls) |tc| {
                for (tc) |*t| {
                    allocator.free(t.function.name);
                    allocator.free(t.function.arguments);
                }
                allocator.free(tc);
            }
        }

        pub const Message = struct {
            role: []const u8,
            content: []const u8,
            tool_calls: ?[]const ToolCall,

            pub fn deinit(self: *Message, allocator: std.mem.Allocator) void {
                allocator.free(self.role);
                allocator.free(self.content);
                if (self.tool_calls) |tc| {
                    for (tc) |*t| {
                        allocator.free(t.function.name);
                        allocator.free(t.function.arguments);
                    }
                    allocator.free(tc);
                }
            }
        };

        pub const ToolCall = struct {
            function: FunctionCall,
        };

        pub const FunctionCall = struct {
            name: []const u8,
            arguments: []const u8,
        };

        pub const TokenUsage = struct {
            prompt_tokens: u32,
            completion_tokens: u32,
            total_tokens: u32,

            pub fn deinit(self: *TokenUsage, allocator: std.mem.Allocator) void {
                _ = allocator;
                _ = self;
            }
        };
    };

    fn convertToLocalTool(
        self: *const Self,
        schema: *const function.FunctionSchema,
        allocator: std.mem.Allocator
    ) !types.Value {
        _ = self;
        // Ollama uses OpenAI-compatible format
        var tool_obj = std.json.ObjectMap.init(allocator);

        try tool_obj.put(try allocator.dupe(u8, "type"), .{ .string = try allocator.dupe(u8, "function") });

        var function_obj = std.json.ObjectMap.init(allocator);
        try function_obj.put(try allocator.dupe(u8, "name"), .{ .string = schema.name });
        try function_obj.put(try allocator.dupe(u8, "description"), .{ .string = schema.description });

        const params_json = try schema.parameters.toJson(allocator);
        try function_obj.put(try allocator.dupe(u8, "parameters"), params_json);

        try tool_obj.put(try allocator.dupe(u8, "function"), .{ .object = function_obj });

        return .{ .object = tool_obj };
    }

    fn buildToolCallPayload(
        self: *const Self,
        local_tool: types.Value,
        allocator: std.mem.Allocator
    ) !types.Value {
        var root = std.StringHashMap(types.Value).init(allocator);

        try root.put(try allocator.dupe(u8, "model"), .{ .string = self.model });
        try root.put(try allocator.dupe(u8, "stream"), .{ .bool = false });

        var messages = std.array_list.Managed(types.Value).init(allocator);
        var user_msg = std.StringHashMap(types.Value).init(allocator);
        try user_msg.put(try allocator.dupe(u8, "role"), .{ .string = try allocator.dupe(u8, "user") });
        try user_msg.put(try allocator.dupe(u8, "content"), .{ .string = try allocator.dupe(u8, "Please execute the requested function.") });
        try messages.append(.{ .object = user_msg });
        try root.put(try allocator.dupe(u8, "messages"), .{ .array = messages });

        var tools = std.array_list.Managed(types.Value).init(allocator);
        try tools.append(local_tool);
        try root.put(try allocator.dupe(u8, "tools"), .{ .array = tools });

        var result_obj = std.json.ObjectMap.init(allocator);
        var it = root.iterator();
        while (it.next()) |entry| {
            const key_dup = try allocator.dupe(u8, entry.key_ptr.*);
            try result_obj.put(key_dup, entry.value_ptr.*);
        }

        return .{ .object = result_obj };
    }

    fn buildChatPayload(
        self: *const Self,
        messages: []const ChatMessage,
        tools: ?[]const function.FunctionSchema,
        allocator: std.mem.Allocator
    ) !types.Value {
        var root = std.StringHashMap(types.Value).init(allocator);

        try root.put(try allocator.dupe(u8, "model"), .{ .string = self.model });
        try root.put(try allocator.dupe(u8, "stream"), .{ .bool = false });

        var msg_array = std.array_list.Managed(types.Value).init(allocator);
        for (messages) |msg| {
            var msg_obj = std.StringHashMap(types.Value).init(allocator);
            try msg_obj.put(try allocator.dupe(u8, "role"), .{ .string = try allocator.dupe(u8, msg.role) });
            try msg_obj.put(try allocator.dupe(u8, "content"), .{ .string = try allocator.dupe(u8, msg.content) });
            try msg_array.append(.{ .object = msg_obj });
        }
        try root.put(try allocator.dupe(u8, "messages"), .{ .array = msg_array });

        if (tools) |schemas| {
            var tools_array = std.array_list.Managed(types.Value).init(allocator);
            for (schemas) |schema| {
                const tool = try self.convertToLocalTool(&schema, allocator);
                try tools_array.append(tool);
            }
            try root.put(try allocator.dupe(u8, "tools"), .{ .array = tools_array });
        }

        var result_obj = std.json.ObjectMap.init(allocator);
        var it = root.iterator();
        while (it.next()) |entry| {
            const key_dup = try allocator.dupe(u8, entry.key_ptr.*);
            try result_obj.put(key_dup, entry.value_ptr.*);
        }

        return .{ .object = result_obj };
    }

    fn makeApiCall(
        self: *const Self,
        endpoint: []const u8,
        payload: types.Value,
        allocator: std.mem.Allocator
    ) ![]const u8 {
        // Warn if TLS certificate validation is disabled (CWE-295)
        // Only warn for HTTPS endpoints - localhost uses HTTP
        if (std.mem.startsWith(u8, self.base_url, "https://") and !self.tls_config.validate_certificates) {
            std.log.warn("SECURITY WARNING: TLS certificate validation is DISABLED for Local provider. This should NEVER be used in production.", .{});
        }

        const payload_str = try std.json.stringifyAlloc(allocator, payload, .{});
        defer allocator.free(payload_str);

        var url_buffer: [512]u8 = undefined;
        const url = try std.fmt.bufPrint(&url_buffer, "{s}{s}", .{ self.base_url, endpoint });

        const uri = try std.Uri.parse(url);

        // Prepare extra headers with new Zig 0.15.2 API
        var header_buffer: [1]std.http.Header = undefined;
        header_buffer[0] = .{ .name = "Content-Type", .value = "application/json" };

        // Note: Zig's std.http.Client performs TLS certificate validation by default for HTTPS
        var request = try self.http_client.request(.POST, uri, .{
            .extra_headers = &header_buffer,
        });
        defer request.deinit();

        // Write request body
        try request.writeAll(payload_str);

        // Send request and receive response headers
        var response = try request.receiveHead(&.{});

        // Check status
        if (request.response.status != .ok) {
            // Read error body
            var error_buffer: [1024]u8 = undefined;
            var error_body = std.array_list.Managed(u8).init(allocator);
            var reader_buffer: [1024]u8 = undefined;
            const body_reader = try response.reader(&reader_buffer).readAllArrayList(&error_body, error_buffer[0..]);
            _ = body_reader;
            std.log.err("Local provider API returned status {d}: {s}", .{ @intFromEnum(request.response.status), error_body.items });
            return error.HttpError;
        }

        // Read response body
        var response_body = std.array_list.Managed(u8).init(allocator);
        var reader_buffer: [8192]u8 = undefined;
        const body_reader = try response.reader(&reader_buffer);
        try body_reader.readAllArrayList(&response_body, 1024 * 1024);

        return response_body.toOwnedSlice();
    }

    fn parseToolResponse(
        self: *const Self,
        response_body: []const u8,
        allocator: std.mem.Allocator
    ) !types.FunctionResult {
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, response_body, .{});
        defer parsed.deinit();

        const root = parsed.value;

        const message = root.object.get("message") orelse return error.InvalidJsonStructure;

        const tool_calls = message.object.get("tool_calls") orelse return error.InvalidResponse;
        if (tool_calls != .array or tool_calls.array.items.len == 0) return error.InvalidResponse;

        const first_tool = tool_calls.array.items[0];
        const function_obj = first_tool.object.get("function") orelse return error.InvalidJsonStructure;

        const function_name = function_obj.object.get("name") orelse return error.InvalidJsonStructure;
        const arguments_str = function_obj.object.get("arguments") orelse return error.InvalidJsonStructure;

        const args_parsed = try std.json.parseFromSlice(std.json.Value, allocator, arguments_str.string, .{});
        defer args_parsed.deinit();

        var tokens_used: ?types.TokenUsage = null;
        if (root.object.get("prompt_eval_count")) |pc| {
            if (root.object.get("eval_count")) |ec| {
                if (pc == .float and ec == .float) {
                    tokens_used = types.TokenUsage{
                        .prompt_tokens = @intFromFloat(pc.float),
                        .completion_tokens = @intFromFloat(ec.float),
                        .total_tokens = @intFromFloat(pc.float + ec.float),
                    };
                }
            }
        }

        return types.FunctionResult{
            .function_name = try allocator.dupe(u8, function_name.string),
            .arguments = args_parsed.value,
            .raw_response = try allocator.dupe(u8, response_body),
            .provider = try allocator.dupe(u8, "local"),
            .model = try allocator.dupe(u8, self.model),
            .tokens_used = tokens_used,
        };
    }

    fn parseChatResponse(
        self: *const Self,
        response_body: []const u8,
        allocator: std.mem.Allocator
    ) !ChatResponse {
        _ = self;
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, response_body, .{});
        defer parsed.deinit();

        const root = parsed.value;

        const model = root.object.get("model") orelse return error.InvalidJsonStructure;
        const created_at = root.object.get("created_at") orelse return error.InvalidJsonStructure;
        const message = root.object.get("message") orelse return error.InvalidJsonStructure;
        const done = root.object.get("done") orelse return error.InvalidJsonStructure;

        const role = message.object.get("role") orelse return error.InvalidJsonStructure;
        const content = message.object.get("content") orelse return error.InvalidJsonStructure;

        var tool_calls: ?[]const ChatResponse.ToolCall = null;
        if (message.object.get("tool_calls")) |tc| {
            if (tc == .array and tc.array.items.len > 0) {
                var tc_list = std.ArrayList(ChatResponse.ToolCall).initCapacity(allocator, 0) catch return error.OutOfMemory;
                for (tc.array.items) |tc_item| {
                    const function_obj = tc_item.object.get("function") orelse continue;
                    const name = function_obj.object.get("name") orelse continue;
                    const args = function_obj.object.get("arguments") orelse continue;

                    if (name == .string and args == .string) {
                        try tc_list.append(.{
                            .function = .{
                                .name = try allocator.dupe(u8, name.string),
                                .arguments = try allocator.dupe(u8, args.string),
                            },
                        });
                    }
                }
                tool_calls = try tc_list.toOwnedSlice();
            }
        }

        const msg_response = ChatResponse.Message{
            .role = try allocator.dupe(u8, role.string),
            .content = try allocator.dupe(u8, if (content == .string) content.string else ""),
            .tool_calls = tool_calls,
        };

        var usage: ?ChatResponse.TokenUsage = null;
        if (root.object.get("prompt_eval_count")) |pc| {
            if (root.object.get("eval_count")) |ec| {
                if (pc == .float and ec == .float) {
                    usage = ChatResponse.TokenUsage{
                        .prompt_tokens = @intFromFloat(pc.float),
                        .completion_tokens = @intFromFloat(ec.float),
                        .total_tokens = @intFromFloat(pc.float + ec.float),
                    };
                }
            }
        }

        return ChatResponse{
            .model = try allocator.dupe(u8, model.string),
            .created_at = try allocator.dupe(u8, created_at.string),
            .message = msg_response,
            .done = done == .bool and done.bool,
            .usage = usage,
            .tool_calls = tool_calls,
        };
    }

    pub fn Config_deinit(self: *Config, allocator: std.mem.Allocator) void {
        allocator.free(self.base_url);
        allocator.free(self.model);
    }
};

test "local_provider_initialization" {
    const config = LocalProvider.Config{
        .base_url = "http://localhost:11434",
        .model = "llama3.2",
    };

    var provider = try LocalProvider.init(std.testing.allocator, config);
    provider.deinit(std.testing.allocator);

    try std.testing.expect(true);
}

test "local_provider_capabilities" {
    const config = LocalProvider.Config{
        .base_url = "http://localhost:11434",
    };

    var provider = try LocalProvider.init(std.testing.allocator, config);
    defer provider.deinit(std.testing.allocator);

    const caps = provider.get_capabilities();
    try std.testing.expect(caps.supports_function_calling);
    try std.testing.expect(!caps.supports_parallel_calls);
}

test "local_parse_tool_response" {
    const config = LocalProvider.Config{
        .base_url = "http://localhost:11434",
        .model = "llama3.2",
    };

    var provider = try LocalProvider.init(std.testing.allocator, config);
    defer provider.deinit(std.testing.allocator);

    const mock_response =
        \\{
        \\  "model": "llama3.2",
        \\  "created_at": "2024-01-01T00:00:00Z",
        \\  "message": {
        \\    "role": "assistant",
        \\    "content": "",
        \\    "tool_calls": [{
        \\      "function": {
        \\        "name": "test_function",
        \\        "arguments": "{\"param1\": \"value1\"}"
        \\      }
        \\    }]
        \\  },
        \\  "done": true,
        \\  "prompt_eval_count": 10,
        \\  "eval_count": 5
        \\}
    ;

    const result = try provider.parseToolResponse(mock_response, std.testing.allocator);
    defer {
        std.testing.allocator.free(result.function_name);
        std.testing.allocator.free(result.raw_response);
        std.testing.allocator.free(result.provider);
        std.testing.allocator.free(result.model);
        if (result.tokens_used) |*t| t.deinit(std.testing.allocator);
    }

    try std.testing.expectEqualStrings("test_function", result.function_name);
    try std.testing.expectEqualStrings("local", result.provider);
    try std.testing.expect(result.tokens_used != null);
    if (result.tokens_used) |tokens| {
        try std.testing.expectEqual(@as(u32, 15), tokens.total_tokens);
    }
}

test "local_validate_response_success" {
    const config = LocalProvider.Config{
        .base_url = "http://localhost:11434",
    };

    var provider = try LocalProvider.init(std.testing.allocator, config);
    defer provider.deinit(std.testing.allocator);

    var result = types.FunctionResult{
        .function_name = "test_func",
        .arguments = .{ .object = std.json.ObjectMap.init(std.testing.allocator) },
        .raw_response = "{}",
        .provider = "local",
        .model = "llama3.2",
        .tokens_used = null,
    };
    defer {
        std.testing.allocator.free(result.function_name);
        std.testing.allocator.free(result.raw_response);
        std.testing.allocator.free(result.provider);
        std.testing.allocator.free(result.model);
        if (result.arguments == .object) result.arguments.object.deinit();
    }

    const validation = try provider.validate_response(result, std.testing.allocator);
    defer validation.deinit(std.testing.allocator);

    try std.testing.expect(validation.is_valid);
}

test "local_validate_response_errors" {
    const config = LocalProvider.Config{
        .base_url = "http://localhost:11434",
    };

    var provider = try LocalProvider.init(std.testing.allocator, config);
    defer provider.deinit(std.testing.allocator);

    const result = types.FunctionResult{
        .function_name = "",
        .arguments = .{ .string = "invalid" },
        .raw_response = "{}",
        .provider = "local",
        .model = "llama3.2",
        .tokens_used = null,
    };
    defer {
        std.testing.allocator.free(result.function_name);
        std.testing.allocator.free(result.raw_response);
        std.testing.allocator.free(result.provider);
        std.testing.allocator.free(result.model);
    }

    const validation = try provider.validate_response(result, std.testing.allocator);
    defer validation.deinit(std.testing.allocator);

    try std.testing.expect(!validation.is_valid);
    try std.testing.expectEqual(@as(usize, 2), validation.errors.len);
}
