# Function Calling Framework for AI Intelligence Layer

## Purpose

Structured function calling interface for AI operations. Provides JSON Schema generation, parameter validation, and result parsing for type-safe LLM function invocation across different providers.

## Types

### SchemaType

**Description**: JSON Schema type enumeration

**Variants**:
- `String` - String values
- `Number` - Floating point numbers
- `Integer` - Integer values
- `Boolean` - True/false values
- `Array` - Ordered lists
- `Object` - Key-value maps
- `Null` - Null values

### JSONSchema

**Description**: JSON Schema definition for validation

**Fields**:
- `type: SchemaType` - Type of value
- `description: Option<String>` - Human-readable description
- `properties: Option<HashMap<String, JSONSchema>>` - Object properties (for type Object)
- `required: Option<Vec<String>>` - Required property names (for type Object)
- `items: Option<Box<JSONSchema>>` - Array item schema (for type Array)
- `enum_values: Option<Vec<Value>>` - Allowed enum values
- `additional_properties: Option<bool>` - Allow extra properties (for type Object)

**Invariants**:
- For `type == Object`: `properties` defined, `required` optional
- For `type == Array`: `items` defined
- For `type == String/Number`: `enum_values` optional
- `additional_properties` only relevant for `type == Object`

### FunctionSchema

**Description**: Complete function definition for LLM calling

**Fields**:
- `name: String` - Function identifier (must be unique)
- `description: String` - Function description for LLM
- `parameters: JSONSchema` - Parameter schema (type Object)
- `returns: Option<JSONSchema>` - Return value schema

**Invariants**:
- `name` is non-empty and matches regex `[a-zA-Z_][a-zA-Z0-9_]*`
- `parameters.type == Object`
- `description` is non-empty

### Value

**Description**: JSON value enum (use serde_json::Value)

**Variants**:
- `Null` - Null value
- `Bool(bool)` - Boolean
- `Number(f64)` - Integer or float (use i64/u64 for integers)
- `String(String)` - UTF-8 string
- `Array(Vec<Value>)` - Ordered list
- `Object(Map<String, Value>)` - Key-value map

## Functions

### JSONSchema::new(type: SchemaType) -> Self

**Purpose**: Create new schema with minimal fields

**Algorithm**:
1. Create JSONSchema with given type
2. Set all optional fields to None
3. Return instance

### JSONSchema::set_description(&mut self, desc: String)

**Purpose**: Set description for schema

**Algorithm**:
1. Free existing description if present
2. Store description copy

### JSONSchema::add_property(&mut self, name: String, schema: JSONSchema)

**Purpose**: Add property to object schema

**Algorithm**:
1. Initialize properties HashMap if None
2. Insert name -> schema mapping

**Precondition**: `self.type == Object`

### JSONSchema::add_required(&mut self, field: String)

**Purpose**: Mark property as required

**Algorithm**:
1. Initialize required Vec if None
2. Append field name to required list

**Precondition**: `self.type == Object`

### JSONSchema::to_json(&self) -> Result<Value, Error>

**Purpose**: Convert schema to JSON for serialization

**Algorithm**:
1. Create object with "type" field
2. Add "description" if present
3. For Object: add "properties" and "required"
4. For Array: add "items"
5. Add "enum" if enum_values present
6. Add "additionalProperties" if set
7. Return JSON object

### JSONSchema::validate(&self, value: &Value) -> Result<(), ValidationError>

**Purpose**: Validate value against schema

**Algorithm**:
1. Match on schema type:
   - `String`: Check value is String, check enum if present
   - `Number`: Check value is Number, check enum if present
   - `Integer`: Check value is Number with no fractional part
   - `Boolean`: Check value is Bool
   - `Null`: Check value is Null
   - `Array`: Check value is Array, validate each item if items schema present
   - `Object`: Check value is Object, verify required fields, validate each property
2. Return error on validation failure
3. Return success if all checks pass

**Error Conditions**:
- `Error::TypeMismatch`: Value type doesn't match schema type
- `Error::MissingRequiredField`: Required field not present
- `Error::InvalidEnumValue`: Value not in allowed enum

### FunctionSchema::new(name: String, description: String, parameters: JSONSchema) -> Self

**Purpose**: Create new function schema

**Algorithm**:
1. Validate name format
2. Validate parameters is Object type
3. Create FunctionSchema with fields
4. Set returns to None

**Error Conditions**:
- `Error::InvalidFunctionName`: Name doesn't match allowed pattern

### FunctionSchema::to_openai_format(&self) -> Result<Value, Error>

**Purpose**: Convert to OpenAI function calling format

**Algorithm**:
1. Create JSON object
2. Add "name": self.name
3. Add "description": self.description
4. Add "parameters": self.parameters.to_json()
5. Return object

**OpenAI Format**:
```json
{
  "name": "function_name",
  "description": "Function description",
  "parameters": { JSON Schema }
}
```

### FunctionSchema::to_anthropic_format(&self) -> Result<Value, Error>

**Purpose**: Convert to Anthropic tool format

**Algorithm**:
1. Create JSON object
2. Add "name": self.name
3. Add "description": self.description
4. Add "input_schema": self.parameters.to_json()
5. Return object

**Anthropic Format**:
```json
{
  "name": "function_name",
  "description": "Function description",
  "input_schema": { JSON Schema }
}
```

### FunctionSchema::validate_parameters(&self, params: &Value) -> Result<(), ValidationError>

**Purpose**: Validate parameters against function schema

**Algorithm**: Delegate to `self.parameters.validate(params)`

### FunctionSchema::validate_result(&self, result: &Value) -> Result<(), ValidationError>

**Purpose**: Validate result against return schema

**Algorithm**:
1. If `returns` is None, return success (no validation)
2. Otherwise delegate to `selfreturns.validate(result)`

## Validation Errors

### ValidationError

**Description**: Detailed validation error

**Fields**:
- `field: Option<String>` - Field that failed (None for general errors)
- `message: String` - Error message
- `expected: Option<String>` - Expected type/value
- `actual: Option<String>` - Actual type/value

### TypeMismatchError

**Description**: Value doesn't match expected type

**Fields**: Inherits from ValidationError

### MissingRequiredFieldError

**Description**: Required field missing from object

**Fields**:
- `field: String` - Missing field name

## Function Registry

### FunctionRegistry

**Description**: Registry of available functions for LLM calling

**Fields**:
- `functions: HashMap<String, FunctionSchema>` - Registered functions

**Methods**:
- `register(&mut self, schema: FunctionSchema)` - Register function
- `get(&self, name: &str) -> Option<&FunctionSchema>` - Lookup function
- `list(&self) -> Vec<&str>` - List all function names
- `validate_call(&self, name: &str, params: &Value) -> Result<(), ValidationError>` - Validate function call

## Dependencies

- **Uses**: serde_json for JSON serialization
- **Used by**: LLM providers, plugin system

## Rust Implementation Guidance

### Module Structure

```
northstar-ai/llm/
  function/
    mod.rs       - Public API
  schema.rs      - JSONSchema types
  validation.rs  - Validation logic
  registry.rs    - FunctionRegistry
```

### Type Definitions

- **JSONSchema**: Struct with optional fields
- **FunctionSchema**: Struct with name, description, parameters, returns
- **Value**: Use `serde_json::Value` directly
- **SchemaType**: Use `enum SchemaType { String, Number, Integer, Boolean, Array, Object, Null }`

### Concurrency

- **JSONSchema**: `Send + Sync` if all contained types are
- **FunctionRegistry**: Use `DashMap<String, Arc<FunctionSchema>>` for concurrent access
- **FunctionSchema**: `Send + Sync` if strings are owned

### Key Decisions

- **JSON library**: Use `serde_json` for de/serialization
- **Validation**: Implement recursive validation with early exit
- **Error types**: Use `thiserror` for ValidationError hierarchy
- **Enum handling**: Store as `Vec<serde_json::Value>` for type flexibility

### Implementation Notes

1. Implement `Display` for ValidationError for user-friendly messages
2. Use `Arc<JSONSchema>` for shared schemas in enums/arrays
3. Implement `Clone` for JSONSchema (deep clone)
4. Add `#[non_exhaustive]` to allow future fields
5. Use ` Cow<str>` for borrowed/owned string flexibility

### Testing Strategy

**Unit tests for**:
- Schema construction (add_property, add_required)
- JSON serialization/deserialization
- Validation for each schema type
- Enum validation
- Required field validation
- Nested object/array validation

**Property tests for**:
- Round-trip: schema -> JSON -> schema
- Validation: valid values pass, invalid values fail
- Deep clone produces equivalent schema

**Integration scenarios**:
- Register functions in registry
- Validate function calls from LLM responses
- Convert to OpenAI/Anthropic formats
