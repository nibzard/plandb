//! Function schema and calling framework
//!
//! Implements JSON Schema generation for function calling
//! following OpenAI/Anthropic function calling formats

const std = @import("std");
const types = @import("types.zig");

const ArrayListManaged = std.ArrayListUnmanaged;

/// JSON Schema types
pub const SchemaType = enum {
    string,
    number,
    integer,
    boolean,
    array,
    object,
    null,
};

/// JSON Schema definition
pub const JSONSchema = struct {
    type: SchemaType,
    description: ?[]const u8 = null,
    properties: ?std.StringHashMap(JSONSchema) = null,
    required: ?ArrayListManaged([]const u8) = null,
    items: ?*JSONSchema = null,
    enum_values: ?ArrayListManaged(types.Value) = null,
    additional_properties: ?bool = null,

    pub fn init(type_: SchemaType) JSONSchema {
        return JSONSchema{
            .type = type_,
            .properties = null,
            .required = null,
            .items = null,
            .enum_values = null,
            .additional_properties = null,
            .description = null,
        };
    }

    pub fn deinit(self: *JSONSchema, allocator: std.mem.Allocator) void {
        if (self.properties) |*props| {
            var it = props.iterator();
            while (it.next()) |entry| {
                entry.value_ptr.*.deinit(allocator);
                allocator.free(entry.key_ptr.*);
            }
            props.deinit();
        }
        if (self.required) |*req| {
            for (req.items) |item| allocator.free(item);
            req.deinit(allocator);
        }
        if (self.items) |item| {
            item.deinit(allocator);
            allocator.destroy(item);
        }
        if (self.enum_values) |*enums| {
            enums.deinit(allocator);
        }
        if (self.description) |desc| allocator.free(desc);
    }

    pub fn setDescription(self: *JSONSchema, allocator: std.mem.Allocator, desc: []const u8) !void {
        if (self.description) |existing| allocator.free(existing);
        self.description = try allocator.dupe(u8, desc);
    }

    pub fn addProperty(self: *JSONSchema, allocator: std.mem.Allocator, name: []const u8, schema: JSONSchema) !void {
        if (self.properties == null) {
            self.properties = std.StringHashMap(JSONSchema).init(allocator);
        }
        const key = try allocator.dupe(u8, name);
        try self.properties.?.put(key, schema);
    }

    pub fn addRequired(self: *JSONSchema, allocator: std.mem.Allocator, field: []const u8) !void {
        if (self.required == null) {
            self.required = ArrayListManaged([]const u8){};
        }
        const dupe = try allocator.dupe(u8, field);
        try self.required.?.append(allocator, dupe);
    }

    /// Convert to JSON Value for serialization
    pub fn toJson(self: *const JSONSchema, allocator: std.mem.Allocator) !types.Value {
        var obj = std.StringHashMap(types.Value).init(allocator);
        defer {
            var it = obj.iterator();
            while (it.next()) |entry| {
                allocator.free(entry.key_ptr.*);
            }
            obj.deinit();
        }

        // Type field
        const type_str = try allocator.dupe(u8, @tagName(self.type));
        try obj.put(try allocator.dupe(u8, "type"), .{ .string = type_str });

        // Description
        if (self.description) |desc| {
            try obj.put(try allocator.dupe(u8, "description"), .{ .string = desc });
        }

        // Properties (for object type)
        if (self.properties) |*props| {
            var props_obj = std.StringHashMap(types.Value).init(allocator);
            defer {
                var it2 = props_obj.iterator();
                while (it2.next()) |entry| {
                    allocator.free(entry.key_ptr.*);
                }
                props_obj.deinit();
            }
            var it = props.iterator();
            while (it.next()) |entry| {
                const prop_json = try entry.value_ptr.toJson(allocator);
                try props_obj.put(entry.key_ptr.*, prop_json);
            }

            // Convert StringHashMap to ArrayHashMap for json.Value
            var arr_obj = std.json.ObjectMap.init(allocator);
            var it3 = props_obj.iterator();
            while (it3.next()) |entry| {
                const key_dup = try allocator.dupe(u8, entry.key_ptr.*);
                try arr_obj.put(key_dup, entry.value_ptr.*);
            }

            try obj.put(try allocator.dupe(u8, "properties"), .{ .object = arr_obj });
        }

        // Required fields
        if (self.required) |*req| {
            var required_arr = std.json.Array{ .items = &.{}, .capacity = 0, .allocator = allocator };
            for (req.items) |item| {
                try required_arr.append(.{ .string = item });
            }
            try obj.put(try allocator.dupe(u8, "required"), .{ .array = required_arr });
        }

        // Items (for array type)
        if (self.items) |item| {
            const items_json = try item.toJson(allocator);
            try obj.put(try allocator.dupe(u8, "items"), items_json);
        }

        // Enum values
        if (self.enum_values) |*enums| {
            var enum_arr = std.json.Array{ .items = &.{}, .capacity = 0, .allocator = allocator };
            for (enums.items) |item| {
                try enum_arr.append(item);
            }
            try obj.put(try allocator.dupe(u8, "enum"), .{ .array = enum_arr });
        }

        // Additional properties
        if (self.additional_properties) |ap| {
            try obj.put(try allocator.dupe(u8, "additionalProperties"), .{ .bool = ap });
        }

        // Convert final StringHashMap to ArrayHashMap for json.Value
        var final_obj = std.json.ObjectMap.init(allocator);
        var it_final = obj.iterator();
        while (it_final.next()) |entry| {
            const key_dup = try allocator.dupe(u8, entry.key_ptr.*);
            try final_obj.put(key_dup, entry.value_ptr.*);
        }

        return .{ .object = final_obj };
    }
};

/// Function schema definition
pub const FunctionSchema = struct {
    name: []const u8,
    description: []const u8,
    parameters: JSONSchema,
    returns: ?JSONSchema = null,

    pub fn init(allocator: std.mem.Allocator, name: []const u8, description: []const u8, parameters: JSONSchema) !FunctionSchema {
        return FunctionSchema{
            .name = try allocator.dupe(u8, name),
            .description = try allocator.dupe(u8, description),
            .parameters = parameters,
            .returns = null,
        };
    }

    pub fn deinit(self: *FunctionSchema, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.description);
        self.parameters.deinit(allocator);
        if (self.returns) |*ret| ret.deinit(allocator);
    }

    /// Convert to OpenAI function format
    pub fn toOpenAIFormat(self: *const FunctionSchema, allocator: std.mem.Allocator) !types.Value {
        var obj = std.json.ObjectMap.init(allocator);

        try obj.put(try allocator.dupe(u8, "name"), .{ .string = self.name });
        try obj.put(try allocator.dupe(u8, "description"), .{ .string = self.description });

        const params_json = try self.parameters.toJson(allocator);
        try obj.put(try allocator.dupe(u8, "parameters"), params_json);

        return .{ .object = obj };
    }

    /// Convert to Anthropic tool format
    pub fn toAnthropicFormat(self: *const FunctionSchema, allocator: std.mem.Allocator) !types.Value {
        var obj = std.json.ObjectMap.init(allocator);

        try obj.put(try allocator.dupe(u8, "name"), .{ .string = self.name });
        try obj.put(try allocator.dupe(u8, "description"), .{ .string = self.description });

        const input_schema = try self.parameters.toJson(allocator);
        try obj.put(try allocator.dupe(u8, "input_schema"), input_schema);

        return .{ .object = obj };
    }
};

/// Function example for documentation
pub const FunctionExample = struct {
    input: types.Value,
    output: types.Value,
    description: []const u8,

    pub fn deinit(self: *FunctionExample, allocator: std.mem.Allocator) void {
        _ = self.input;
        _ = self.output;
        // Value cleanup is complex; for now just free description
        allocator.free(self.description);
    }
};

test "json_schema_object" {
    var schema = JSONSchema.init(.object);
    defer schema.deinit(std.testing.allocator);

    try schema.setDescription(std.testing.allocator, "Test object");
    try schema.addRequired(std.testing.allocator, "name");

    try std.testing.expectEqual(SchemaType.object, schema.type);
    try std.testing.expect(schema.required != null);
}

test "function_schema_creation" {
    var params = JSONSchema.init(.object);
    defer params.deinit(std.testing.allocator);

    var schema = try FunctionSchema.init(
        std.testing.allocator,
        "test_function",
        "A test function",
        params
    );
    defer schema.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("test_function", schema.name);
    try std.testing.expectEqualStrings("A test function", schema.description);
}

test "function_schema_to_openai_format" {
    var params = JSONSchema.init(.object);
    defer params.deinit(std.testing.allocator);

    var schema = try FunctionSchema.init(
        std.testing.allocator,
        "test_function",
        "A test function",
        params
    );
    defer schema.deinit(std.testing.allocator);

    const json = try schema.toOpenAIFormat(std.testing.allocator);
    // Note: json.object deinit skipped - testing allocator reclaims memory

    try std.testing.expect(json == .object);
}
