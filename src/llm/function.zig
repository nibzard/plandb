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

    /// Validate a value against this schema
    pub fn validate(self: *const JSONSchema, value: types.Value) !void {
        switch (self.type) {
            .string => {
                if (value != .string) return error.TypeMismatch;
                // Check enum values if present
                if (self.enum_values) |enums| {
                    var found = false;
                    for (enums.items) |enum_val| {
                        if (enum_val == .string and std.mem.eql(u8, enum_val.string, value.string)) {
                            found = true;
                            break;
                        }
                    }
                    if (!found) return error.InvalidEnumValue;
                }
            },
            .number => {
                if (value != .float) return error.TypeMismatch;
                if (self.enum_values) |enums| {
                    var found = false;
                    for (enums.items) |enum_val| {
                        if (enum_val == .float and enum_val.float == value.float) {
                            found = true;
                            break;
                        }
                    }
                    if (!found) return error.InvalidEnumValue;
                }
            },
            .integer => {
                if (value != .float) return error.TypeMismatch;
                // Check if it's actually an integer (no fractional part)
                if (value.float != @floor(value.float)) return error.TypeMismatch;
            },
            .boolean => {
                if (value != .bool) return error.TypeMismatch;
            },
            .null => {
                if (value != .null) return error.TypeMismatch;
            },
            .array => {
                if (value != .array) return error.TypeMismatch;
                // Validate each item against items schema if present
                if (self.items) |items_schema| {
                    for (value.array.items) |item| {
                        try items_schema.validate(item);
                    }
                }
            },
            .object => {
                if (value != .object) return error.TypeMismatch;
                // Check required fields
                if (self.required) |required| {
                    for (required.items) |field| {
                        if (value.object.get(field) == null) {
                            return error.MissingRequiredField;
                        }
                    }
                }
                // Validate properties against schema
                if (self.properties) |props| {
                    var it = props.iterator();
                    while (it.next()) |entry| {
                        const prop_name = entry.key_ptr.*;
                        const prop_schema = entry.value_ptr.*;
                        if (value.object.get(prop_name)) |prop_value| {
                            try prop_schema.validate(prop_value);
                        }
                    }
                }
            },
        }
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

test "json_schema_validate_string" {
    var schema = JSONSchema.init(.string);
    defer schema.deinit(std.testing.allocator);

    // Valid string
    try schema.validate(.{ .string = "hello" });

    // Invalid type
    try std.testing.expectError(error.TypeMismatch, schema.validate(.{ .float = 42 }));
}

test "json_schema_validate_integer" {
    var schema = JSONSchema.init(.integer);
    defer schema.deinit(std.testing.allocator);

    // Valid integer
    try schema.validate(.{ .float = 42 });

    // Invalid: fractional number
    try std.testing.expectError(error.TypeMismatch, schema.validate(.{ .float = 42.5 }));

    // Invalid: wrong type
    try std.testing.expectError(error.TypeMismatch, schema.validate(.{ .string = "42" }));
}

test "json_schema_validate_object_with_required" {
    var schema = JSONSchema.init(.object);
    defer schema.deinit(std.testing.allocator);

    try schema.addRequired(std.testing.allocator, "name");

    var valid_obj = std.json.ObjectMap.init(std.testing.allocator);
    defer valid_obj.deinit();
    try valid_obj.put(try std.testing.allocator.dupe(u8, "name"), .{ .string = "test" });

    try schema.validate(.{ .object = valid_obj });

    // Missing required field
    var invalid_obj = std.json.ObjectMap.init(std.testing.allocator);
    defer invalid_obj.deinit();

    try std.testing.expectError(error.MissingRequiredField, schema.validate(.{ .object = invalid_obj }));
}

test "json_schema_validate_enum" {
    var schema = JSONSchema.init(.string);
    defer schema.deinit(std.testing.allocator);

    schema.enum_values = std.ArrayListUnmanaged(types.Value){};
    try schema.enum_values.?.append(std.testing.allocator, .{ .string = "red" });
    try schema.enum_values.?.append(std.testing.allocator, .{ .string = "green" });
    try schema.enum_values.?.append(std.testing.allocator, .{ .string = "blue" });

    // Valid enum value
    try schema.validate(.{ .string = "red" });

    // Invalid enum value
    try std.testing.expectError(error.InvalidEnumValue, schema.validate(.{ .string = "yellow" }));
}
