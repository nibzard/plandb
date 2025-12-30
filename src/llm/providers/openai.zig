//! OpenAI provider implementation for LLM function calling
//!
//! Implements OpenAI-compatible API for function calling with proper error handling
//! and response validation according to spec/ai_plugins_v1.md.
//!
//! Uses modern OpenAI Chat Completions API with tools format.

const std = @import("std");
const types = @import("../types.zig");
const function = @import("../function.zig");

pub const OpenAIProvider = struct {
    allocator: std.mem.Allocator,
    api_key: []const u8,
    model: []const u8,
    base_url: []const u8,
    timeout_ms: u32,
    max_retries: u32,
    http_client: std.http.Client,

    const Self = @This();

    pub const Config = struct {
        api_key: []const u8,
        model: []const u8 = "gpt-4o",
        base_url: []const u8 = "https://api.openai.com/v1",
        timeout_ms: u32 = 30000,
        max_retries: u32 = 3,
    };

    pub fn init(allocator: std.mem.Allocator, config: Config) !Self {
        return Self{
            .allocator = allocator,
            .api_key = try allocator.dupe(u8, config.api_key),
            .model = try allocator.dupe(u8, config.model),
            .base_url = try allocator.dupe(u8, config.base_url),
            .timeout_ms = config.timeout_ms,
            .max_retries = config.max_retries,
            .http_client = std.http.Client{ .allocator = allocator },
        };
    }

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        self.http_client.deinit();
        allocator.free(self.api_key);
        allocator.free(self.model);
        allocator.free(self.base_url);
    }

    pub fn get_capabilities(self: *const Self) types.ProviderCapabilities {
        _ = self;
        return .{
            .max_tokens = 4096,
            .supports_streaming = false,
            .supports_function_calling = true,
            .supports_parallel_calls = true,
            .max_functions_per_call = 10,
            .max_context_length = 128000,
        };
    }

    pub fn call_function(
        self: *const Self,
        schema: function.FunctionSchema,
        params: types.Value,
        allocator: std.mem.Allocator
    ) !types.FunctionResult {
        // Convert schema to OpenAI tool format
        const openai_tool = try self.convertToOpenAITool(&schema, allocator);
        defer {
            if (openai_tool == .object) {
                var it = openai_tool.object.iterator();
                while (it.next()) |entry| {
                    allocator.free(entry.key_ptr.*);
                }
                openai_tool.object.deinit();
            }
        }

        // Build request payload
        const payload = try self.buildToolCallPayload(openai_tool, params, allocator);
        defer {
            if (payload == .object) {
                var it = payload.object.iterator();
                while (it.next()) |entry| {
                    allocator.free(entry.key_ptr.*);
                    if (entry.value_ptr.* == .string) {
                        allocator.free(entry.value_ptr.string);
                    } else if (entry.value_ptr.* == .array) {
                        for (entry.value_ptr.array.items) |item| {
                            if (item == .object) {
                                var it2 = item.object.iterator();
                                while (it2.next()) |e| {
                                    allocator.free(e.key_ptr.*);
                                    if (e.value_ptr.* == .string) allocator.free(e.value_ptr.string);
                                }
                                item.object.deinit();
                            }
                        }
                        entry.value_ptr.array.deinit();
                    }
                }
                payload.object.deinit();
            }
        }

        // Make API call
        const response_body = try self.makeApiCall("/chat/completions", payload, allocator);
        defer allocator.free(response_body);

        // Parse and validate response
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

        // Validate function name is present
        if (response.function_name.len == 0) {
            try errors.append(allocator, .{
                .field = try allocator.dupe(u8, "function_name"),
                .message = try allocator.dupe(u8, "Function name is empty"),
            });
        }

        // Validate arguments is an object
        if (response.arguments != .object) {
            try errors.append(allocator, .{
                .field = try allocator.dupe(u8, "arguments"),
                .message = try allocator.dupe(u8, "Arguments must be a JSON object"),
            });
        }

        // Validate tokens_used if present
        if (response.tokens_used) |tokens| {
            if (tokens.total_tokens == 0) {
                try warnings.append(allocator, .{
                    .field = try allocator.dupe(u8, "tokens_used"),
                    .message = try allocator.dupe(u8, "Token usage shows zero tokens"),
                });
            }
        }

        return types.ValidationResult{
            .is_valid = errors.items.len == 0,
            .errors = try errors.toOwnedSlice(allocator),
            .warnings = try warnings.toOwnedSlice(allocator),
        };
    }

    /// Chat completion method for general LLM queries
    pub fn chat(
        self: *const Self,
        messages: []const ChatMessage,
        tools: ?[]const function.FunctionSchema,
        allocator: std.mem.Allocator
    ) !ChatResponse {
        // Build request payload
        const payload = try self.buildChatPayload(messages, tools, allocator);
        defer {
            if (payload == .object) {
                var it = payload.object.iterator();
                while (it.next()) |entry| {
                    allocator.free(entry.key_ptr.*);
                    if (entry.value_ptr.* == .string) {
                        allocator.free(entry.value_ptr.string);
                    } else if (entry.value_ptr.* == .array) {
                        for (entry.value_ptr.array.items) |item| {
                            if (item == .object) {
                                var it2 = item.object.iterator();
                                while (it2.next()) |e| {
                                    allocator.free(e.key_ptr.*);
                                    if (e.value_ptr.* == .string) allocator.free(e.value_ptr.string);
                                }
                                item.object.deinit();
                            }
                        }
                        entry.value_ptr.array.deinit();
                    }
                }
                payload.object.deinit();
            }
        }

        // Make API call
        const response_body = try self.makeApiCall("/chat/completions", payload, allocator);
        defer allocator.free(response_body);

        return try self.parseChatResponse(response_body, allocator);
    }

    pub const ChatMessage = struct {
        role: []const u8,
        content: []const u8,
        tool_call_id: ?[]const u8 = null,
        tool_calls: ?[]const ToolCall = null,
    };

    pub const ToolCall = struct {
        id: []const u8,
        type: []const u8,
        function: FunctionCall,
    };

    pub const FunctionCall = struct {
        name: []const u8,
        arguments: []const u8,
    };

    pub const ChatResponse = struct {
        id: []const u8,
        object: []const u8,
        created: i64,
        model: []const u8,
        choices: []const Choice,
        usage: ?types.TokenUsage,
        tool_calls: ?[]const ToolCall,

        pub fn deinit(self: *ChatResponse, allocator: std.mem.Allocator) void {
            allocator.free(self.id);
            allocator.free(self.object);
            allocator.free(self.model);
            for (self.choices) |*c| c.deinit(allocator);
            allocator.free(self.choices);
            if (self.usage) |*u| u.deinit(allocator);
            if (self.tool_calls) |tc| {
                for (tc) |*t| {
                    allocator.free(t.id);
                    allocator.free(t.type);
                    allocator.free(t.function.name);
                    allocator.free(t.function.arguments);
                }
                allocator.free(tc);
            }
        }

        pub const Choice = struct {
            index: u32,
            message: ResponseMessage,
            finish_reason: []const u8,

            pub fn deinit(self: *Choice, allocator: std.mem.Allocator) void {
                self.message.deinit(allocator);
                allocator.free(self.finish_reason);
            }
        };

        pub const ResponseMessage = struct {
            role: []const u8,
            content: ?[]const u8,
            tool_calls: ?[]const ToolCall,

            pub fn deinit(self: *ResponseMessage, allocator: std.mem.Allocator) void {
                allocator.free(self.role);
                if (self.content) |c| allocator.free(c);
                if (self.tool_calls) |tc| {
                    for (tc) |*t| {
                        allocator.free(t.id);
                        allocator.free(t.type);
                        allocator.free(t.function.name);
                        allocator.free(t.function.arguments);
                    }
                    allocator.free(tc);
                }
            }
        };
    };

    fn convertToOpenAITool(
        self: *const Self,
        schema: *const function.FunctionSchema,
        allocator: std.mem.Allocator
    ) !types.Value {
        _ = self;
        // Modern OpenAI uses tools format with type: "function"
        const function_value = try schema.toOpenAIFormat(allocator);

        var tool_obj = std.json.ObjectMap.init(allocator);
        try tool_obj.put(try allocator.dupe(u8, "type"), .{ .string = try allocator.dupe(u8, "function") });
        try tool_obj.put(try allocator.dupe(u8, "function"), function_value);

        return .{ .object = tool_obj };
    }

    fn buildToolCallPayload(
        self: *const Self,
        openai_tool: types.Value,
        params: types.Value,
        allocator: std.mem.Allocator
    ) !types.Value {
        _ = params;

        var root = std.StringHashMap(types.Value).init(allocator);

        // Model
        try root.put(try allocator.dupe(u8, "model"), .{ .string = self.model });

        // Messages
        var messages = std.array_list.Managed(types.Value).init(allocator);
        var user_msg = std.StringHashMap(types.Value).init(allocator);
        try user_msg.put(try allocator.dupe(u8, "role"), .{ .string = try allocator.dupe(u8, "user") });
        try user_msg.put(try allocator.dupe(u8, "content"), .{ .string = try allocator.dupe(u8, "Please execute the requested function.") });
        try messages.append(.{ .object = user_msg });
        try root.put(try allocator.dupe(u8, "messages"), .{ .array = messages });

        // Tools (modern format)
        var tools = std.array_list.Managed(types.Value).init(allocator);
        try tools.append(openai_tool);
        try root.put(try allocator.dupe(u8, "tools"), .{ .array = tools });

        // Tool choice (auto mode)
        try root.put(try allocator.dupe(u8, "tool_choice"), .{ .string = try allocator.dupe(u8, "auto") });

        // Convert to json.ObjectMap
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

        // Model
        try root.put(try allocator.dupe(u8, "model"), .{ .string = self.model });

        // Messages
        var msg_array = std.array_list.Managed(types.Value).init(allocator);
        for (messages) |msg| {
            var msg_obj = std.StringHashMap(types.Value).init(allocator);
            try msg_obj.put(try allocator.dupe(u8, "role"), .{ .string = try allocator.dupe(u8, msg.role) });
            try msg_obj.put(try allocator.dupe(u8, "content"), .{ .string = try allocator.dupe(u8, msg.content) });
            try msg_array.append(.{ .object = msg_obj });
        }
        try root.put(try allocator.dupe(u8, "messages"), .{ .array = msg_array });

        // Tools if provided
        if (tools) |schemas| {
            var tools_array = std.array_list.Managed(types.Value).init(allocator);
            for (schemas) |schema| {
                const tool = try self.convertToOpenAITool(&schema, allocator);
                try tools_array.append(tool);
            }
            try root.put(try allocator.dupe(u8, "tools"), .{ .array = tools_array });
            try root.put(try allocator.dupe(u8, "tool_choice"), .{ .string = try allocator.dupe(u8, "auto") });
        }

        // Convert to json.ObjectMap
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
        // Serialize payload
        const payload_str = try std.json.stringifyAlloc(allocator, payload, .{});
        defer allocator.free(payload_str);

        // Build full URL
        var url_buffer: [512]u8 = undefined;
        const url = try std.fmt.bufPrint(&url_buffer, "{s}{s}", .{ self.base_url, endpoint });

        // Parse URI
        const uri = try std.Uri.parse(url);

        // Prepare extra headers
        var header_buffer: [2]std.http.Header = undefined;
        const auth_header = try std.fmt.allocPrint(allocator, "Bearer {s}", .{self.api_key});
        defer allocator.free(auth_header);

        header_buffer[0] = .{ .name = "Content-Type", .value = "application/json" };
        header_buffer[1] = .{ .name = "Authorization", .value = auth_header };

        // Make request with new Zig 0.15.2 API
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
            std.log.err("OpenAI API returned status {d}: {s}", .{ @intFromEnum(request.response.status), error_body.items });
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

        // Extract choices
        const choices = root.object.get("choices") orelse return error.InvalidJsonStructure;
        if (choices != .array or choices.array.items.len == 0) return error.InvalidJsonStructure;

        const first_choice = choices.array.items[0];
        const message = first_choice.object.get("message") orelse return error.InvalidJsonStructure;

        // Extract tool calls (modern format)
        const tool_calls = message.object.get("tool_calls") orelse return error.InvalidResponse;
        if (tool_calls != .array or tool_calls.array.items.len == 0) return error.InvalidResponse;

        const first_tool = tool_calls.array.items[0];
        const function_obj = first_tool.object.get("function") orelse return error.InvalidJsonStructure;

        const function_name = function_obj.object.get("name") orelse return error.InvalidJsonStructure;
        const arguments_str = function_obj.object.get("arguments") orelse return error.InvalidJsonStructure;

        // Parse arguments
        const args_parsed = try std.json.parseFromSlice(std.json.Value, allocator, arguments_str.string, .{});
        defer args_parsed.deinit();

        // Extract token usage if present
        var tokens_used: ?types.TokenUsage = null;
        if (root.object.get("usage")) |usage| {
            if (usage.object.get("prompt_tokens")) |pt| {
                if (usage.object.get("completion_tokens")) |ct| {
                    if (usage.object.get("total_tokens")) |tt| {
                        if (pt == .float and ct == .float and tt == .float) {
                            tokens_used = types.TokenUsage{
                                .prompt_tokens = @intFromFloat(pt.float),
                                .completion_tokens = @intFromFloat(ct.float),
                                .total_tokens = @intFromFloat(tt.float),
                            };
                        }
                    }
                }
            }
        }

        return types.FunctionResult{
            .function_name = try allocator.dupe(u8, function_name.string),
            .arguments = args_parsed.value,
            .raw_response = try allocator.dupe(u8, response_body),
            .provider = try allocator.dupe(u8, "openai"),
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

        const id = root.object.get("id") orelse return error.InvalidJsonStructure;
        const object = root.object.get("object") orelse return error.InvalidJsonStructure;
        const created = root.object.get("created") orelse return error.InvalidJsonStructure;
        const model_val = root.object.get("model") orelse return error.InvalidJsonStructure;
        const choices = root.object.get("choices") orelse return error.InvalidJsonStructure;

        // Parse choices
        var choice_list = std.array_list.Managed(ChatResponse.Choice).init(allocator);
        errdefer {
            for (choice_list.items) |*c| c.deinit(allocator);
            choice_list.deinit();
        }

        for (choices.array.items) |choice_val| {
            const index = choice_val.object.get("index") orelse return error.InvalidJsonStructure;
            const message = choice_val.object.get("message") orelse return error.InvalidJsonStructure;
            const finish_reason = choice_val.object.get("finish_reason") orelse return error.InvalidJsonStructure;

            const role = message.object.get("role") orelse return error.InvalidJsonStructure;
            const content = message.object.get("content");

            // Parse tool calls if present
            var tool_calls: ?[]const ToolCall = null;
            if (message.object.get("tool_calls")) |tc_val| {
                var tc_list = std.array_list.Managed(ToolCall).init(allocator);
                for (tc_val.array.items) |tc| {
                    const tc_id = tc.object.get("id") orelse return error.InvalidJsonStructure;
                    const tc_type = tc.object.get("type") orelse return error.InvalidJsonStructure;
                    const tc_function = tc.object.get("function") orelse return error.InvalidJsonStructure;

                    const fn_name = tc_function.object.get("name") orelse return error.InvalidJsonStructure;
                    const fn_args = tc_function.object.get("arguments") orelse return error.InvalidJsonStructure;

                    try tc_list.append(.{
                        .id = try allocator.dupe(u8, tc_id.string),
                        .type = try allocator.dupe(u8, tc_type.string),
                        .function = .{
                            .name = try allocator.dupe(u8, fn_name.string),
                            .arguments = try allocator.dupe(u8, fn_args.string),
                        },
                    });
                }
                tool_calls = try tc_list.toOwnedSlice();
            }

            var msg_builder = std.StringHashMap(types.Value).init(allocator);
            try msg_builder.put(try allocator.dupe(u8, "role"), role);
            if (content != null) try msg_builder.put(try allocator.dupe(u8, "content"), content.?);

            const response_message = ChatResponse.ResponseMessage{
                .role = try allocator.dupe(u8, role.string),
                .content = if (content != null and content.? == .string) try allocator.dupe(u8, content.?.string) else null,
                .tool_calls = tool_calls,
            };

            try choice_list.append(.{
                .index = @intFromFloat(index.number),
                .message = response_message,
                .finish_reason = try allocator.dupe(u8, finish_reason.string),
            });
        }

        // Parse usage
        var usage: ?types.TokenUsage = null;
        if (root.object.get("usage")) |usage_val| {
            const pt = usage_val.object.get("prompt_tokens");
            const ct = usage_val.object.get("completion_tokens");
            const tt = usage_val.object.get("total_tokens");

            if (pt != null and pt.? == .float and ct != null and ct.? == .float and tt != null and tt.? == .float) {
                usage = types.TokenUsage{
                    .prompt_tokens = @intFromFloat(pt.?.float),
                    .completion_tokens = @intFromFloat(ct.?.float),
                    .total_tokens = @intFromFloat(tt.?.float),
                };
            }
        }

        return ChatResponse{
            .id = try allocator.dupe(u8, id.string),
            .object = try allocator.dupe(u8, object.string),
            .created = @intFromFloat(created.number),
            .model = try allocator.dupe(u8, model_val.string),
            .choices = try choice_list.toOwnedSlice(),
            .usage = usage,
            .tool_calls = null,
        };
    }

    pub fn Config_deinit(self: *Config, allocator: std.mem.Allocator) void {
        allocator.free(self.api_key);
        allocator.free(self.model);
        allocator.free(self.base_url);
    }
};

test "openai_provider_initialization" {
    const config = OpenAIProvider.Config{
        .api_key = "test-key",
        .model = "gpt-4",
    };

    var provider = try OpenAIProvider.init(std.testing.allocator, config);
    provider.deinit(std.testing.allocator);

    try std.testing.expect(true); // If we got here, initialization worked
}

test "openai_provider_capabilities" {
    const config = OpenAIProvider.Config{
        .api_key = "test-key",
    };

    var provider = try OpenAIProvider.init(std.testing.allocator, config);
    defer provider.deinit(std.testing.allocator);

    const caps = provider.get_capabilities();
    try std.testing.expect(caps.supports_function_calling);
    try std.testing.expect(caps.supports_parallel_calls);
}

test "openai_chat_message_types" {
    const config = OpenAIProvider.Config{
        .api_key = "test-key",
    };

    var provider = try OpenAIProvider.init(std.testing.allocator, config);
    defer provider.deinit(std.testing.allocator);

    // Test chat message structures compile correctly
    const msg = OpenAIProvider.ChatMessage{
        .role = "user",
        .content = "Hello",
        .tool_call_id = null,
        .tool_calls = null,
    };
    _ = msg;

    try std.testing.expect(true);
}

test "openai_tool_format_conversion" {
    const config = OpenAIProvider.Config{
        .api_key = "test-key",
    };

    var provider = try OpenAIProvider.init(std.testing.allocator, config);
    defer provider.deinit(std.testing.allocator);

    // Create a simple function schema
    var params = function.JSONSchema.init(.object);
    defer params.deinit(std.testing.allocator);

    var schema = try function.FunctionSchema.init(
        std.testing.allocator,
        "test_function",
        "A test function",
        params
    );
    defer schema.deinit(std.testing.allocator);

    // Convert to OpenAI tool format
    var tool = try provider.convertToOpenAITool(&schema, std.testing.allocator);
    defer {
        if (tool == .object) {
            var it = tool.object.iterator();
            while (it.next()) |entry| {
                std.testing.allocator.free(entry.key_ptr.*);
            }
            tool.object.deinit();
        }
    }

    try std.testing.expect(tool == .object);
    try std.testing.expect(tool.object.get("type") != null);
}

test "openai_parse_tool_response" {
    const config = OpenAIProvider.Config{
        .api_key = "test-key",
    };

    var provider = try OpenAIProvider.init(std.testing.allocator, config);
    defer provider.deinit(std.testing.allocator);

    const mock_response =
        \\{
        \\  "id": "chatcmpl-123",
        \\  "object": "chat.completion",
        \\  "created": 1677652288,
        \\  "model": "gpt-4o",
        \\  "choices": [{
        \\    "index": 0,
        \\    "message": {
        \\      "role": "assistant",
        \\      "content": null,
        \\      "tool_calls": [{
        \\        "id": "call_abc123",
        \\        "type": "function",
        \\        "function": {
        \\          "name": "test_function",
        \\          "arguments": "{\"param1\": \"value1\"}"
        \\        }
        \\      }]
        \\    },
        \\    "finish_reason": "tool_calls"
        \\  }],
        \\  "usage": {
        \\    "prompt_tokens": 10,
        \\    "completion_tokens": 5,
        \\    "total_tokens": 15
        \\  }
        \\}
    ;

    const result = try provider.parseToolResponse(mock_response, std.testing.allocator);
    defer {
        std.testing.allocator.free(result.function_name);
        std.testing.allocator.free(result.raw_response);
        std.testing.allocator.free(result.provider);
        std.testing.allocator.free(result.model);
        if (result.tokens_used) |*t| t.deinit(std.testing.allocator);
        // arguments is json.Value, allocator will reclaim
    }

    try std.testing.expectEqualStrings("test_function", result.function_name);
    try std.testing.expectEqualStrings("openai", result.provider);
    try std.testing.expect(result.tokens_used != null);
    if (result.tokens_used) |tokens| {
        try std.testing.expectEqual(@as(u32, 15), tokens.total_tokens);
    }
}

test "openai_validate_response_success" {
    const config = OpenAIProvider.Config{
        .api_key = "test-key",
    };

    var provider = try OpenAIProvider.init(std.testing.allocator, config);
    defer provider.deinit(std.testing.allocator);

    // Create a valid function result
    var result = types.FunctionResult{
        .function_name = "test_func",
        .arguments = .{ .object = std.json.ObjectMap.init(std.testing.allocator) },
        .raw_response = "{}",
        .provider = "openai",
        .model = "gpt-4o",
        .tokens_used = types.TokenUsage{
            .prompt_tokens = 10,
            .completion_tokens = 5,
            .total_tokens = 15,
        },
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

test "openai_validate_response_errors" {
    const config = OpenAIProvider.Config{
        .api_key = "test-key",
    };

    var provider = try OpenAIProvider.init(std.testing.allocator, config);
    defer provider.deinit(std.testing.allocator);

    // Create an invalid function result (empty name, wrong args type)
    const result = types.FunctionResult{
        .function_name = "",
        .arguments = .{ .string = "invalid" },
        .raw_response = "{}",
        .provider = "openai",
        .model = "gpt-4o",
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
