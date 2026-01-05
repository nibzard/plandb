//! Function calling schema system
//!
//! This module provides utilities for defining and validating function schemas
//! for LLM function calling. It includes a builder for creating JSON Schema
//! compliant function definitions.

use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::HashMap;

/// Function schema with JSON Schema parameters
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FunctionSchema {
    pub name: String,
    pub description: String,
    pub parameters: ParametersSchema,
}

/// Parameters schema (JSON Schema format)
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ParametersSchema {
    #[serde(rename = "type")]
    pub schema_type: String,

    pub properties: HashMap<String, PropertySchema>,

    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub required: Vec<String>,
}

/// Property schema (for individual parameters)
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PropertySchema {
    #[serde(rename = "type")]
    pub schema_type: String,

    #[serde(skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,

    #[serde(rename = "enum", skip_serializing_if = "Option::is_none")]
    pub enum_values: Option<Vec<Value>>,

    /// Nested object properties
    #[serde(skip_serializing_if = "Option::is_none")]
    pub nested: Option<Box<ParametersSchema>>,
}

/// Builder for creating function schemas
pub struct FunctionSchemaBuilder {
    name: String,
    description: String,
    properties: HashMap<String, PropertySchema>,
    required: Vec<String>,
}

impl FunctionSchemaBuilder {
    pub fn new(name: impl Into<String>, description: impl Into<String>) -> Self {
        Self {
            name: name.into(),
            description: description.into(),
            properties: HashMap::new(),
            required: Vec::new(),
        }
    }

    /// Add a string property
    pub fn add_string_property(
        mut self,
        name: impl Into<String>,
        description: impl Into<String>,
    ) -> Self {
        let prop = PropertySchema {
            schema_type: "string".to_string(),
            description: Some(description.into()),
            enum_values: None,
            nested: None,
        };
        self.properties.insert(name.into(), prop);
        self
    }

    /// Add an integer property
    pub fn add_integer_property(
        mut self,
        name: impl Into<String>,
        description: impl Into<String>,
    ) -> Self {
        let prop = PropertySchema {
            schema_type: "integer".to_string(),
            description: Some(description.into()),
            enum_values: None,
            nested: None,
        };
        self.properties.insert(name.into(), prop);
        self
    }

    /// Add a number property
    pub fn add_number_property(
        mut self,
        name: impl Into<String>,
        description: impl Into<String>,
    ) -> Self {
        let prop = PropertySchema {
            schema_type: "number".to_string(),
            description: Some(description.into()),
            enum_values: None,
            nested: None,
        };
        self.properties.insert(name.into(), prop);
        self
    }

    /// Add a boolean property
    pub fn add_boolean_property(
        mut self,
        name: impl Into<String>,
        description: impl Into<String>,
    ) -> Self {
        let prop = PropertySchema {
            schema_type: "boolean".to_string(),
            description: Some(description.into()),
            enum_values: None,
            nested: None,
        };
        self.properties.insert(name.into(), prop);
        self
    }

    /// Add an array property
    pub fn add_array_property(
        mut self,
        name: impl Into<String>,
        description: impl Into<String>,
        _item_type: impl Into<String>,
    ) -> Self {
        let prop = PropertySchema {
            schema_type: "array".to_string(),
            description: Some(description.into()),
            enum_values: None,
            nested: None,
        };
        self.properties.insert(name.into(), prop);
        self
    }

    /// Add an object property
    pub fn add_object_property(
        mut self,
        name: impl Into<String>,
        description: impl Into<String>,
        nested: ParametersSchema,
    ) -> Self {
        let prop = PropertySchema {
            schema_type: "object".to_string(),
            description: Some(description.into()),
            enum_values: None,
            nested: Some(Box::new(nested)),
        };
        self.properties.insert(name.into(), prop);
        self
    }

    /// Add a property with enum values
    pub fn add_enum_property(
        mut self,
        name: impl Into<String>,
        description: impl Into<String>,
        values: Vec<Value>,
    ) -> Self {
        let prop = PropertySchema {
            schema_type: "string".to_string(),
            description: Some(description.into()),
            enum_values: Some(values),
            nested: None,
        };
        self.properties.insert(name.into(), prop);
        self
    }

    /// Mark a property as required
    pub fn add_required(mut self, name: impl Into<String>) -> Self {
        self.required.push(name.into());
        self
    }

    /// Build the function schema
    pub fn build(self) -> FunctionSchema {
        FunctionSchema {
            name: self.name,
            description: self.description,
            parameters: ParametersSchema {
                schema_type: "object".to_string(),
                properties: self.properties,
                required: self.required,
            },
        }
    }
}

impl From<FunctionSchema> for super::FunctionDefinition {
    fn from(schema: FunctionSchema) -> Self {
        Self {
            name: schema.name,
            description: schema.description,
            parameters: serde_json::to_value(schema.parameters).unwrap(),
            validate_params: true,
        }
    }
}

// Example function schemas

/// Entity extraction function schema
///
/// Extracts entities and topics from database mutations for structured memory.
pub fn entity_extraction_schema() -> super::FunctionDefinition {
    FunctionSchemaBuilder::new(
        "extract_entities",
        "Extract entities and topics from database mutations"
    )
    .add_string_property(
        "mutations",
        "JSON array of database mutations (inserts, updates, deletes)"
    )
    .add_object_property(
        "schema",
        "Database schema information (tables, columns, types)",
        ParametersSchema {
            schema_type: "object".to_string(),
            properties: {
                let mut props = HashMap::new();
                props.insert(
                    "tables".to_string(),
                    PropertySchema {
                        schema_type: "array".to_string(),
                        description: Some("List of table definitions".to_string()),
                        enum_values: None,
                        nested: None,
                    }
                );
                props
            },
            required: vec![],
        }
    )
    .add_object_property(
        "context",
        "Additional context about the transaction",
        ParametersSchema {
            schema_type: "object".to_string(),
            properties: {
                let mut props = HashMap::new();
                props.insert(
                    "user_id".to_string(),
                    PropertySchema {
                        schema_type: "string".to_string(),
                        description: Some("User performing the transaction".to_string()),
                        enum_values: None,
                        nested: None,
                    }
                );
                props.insert(
                    "application".to_string(),
                    PropertySchema {
                        schema_type: "string".to_string(),
                        description: Some("Application name".to_string()),
                        enum_values: None,
                        nested: None,
                    }
                );
                props
            },
            required: vec![],
        }
    )
    .add_required("mutations")
    .add_required("schema")
    .build()
    .into()
}

/// Query translation function schema
///
/// Translates natural language queries to structured SQL.
pub fn query_translation_schema() -> super::FunctionDefinition {
    FunctionSchemaBuilder::new(
        "translate_query",
        "Translate natural language query to SQL"
    )
    .add_string_property(
        "query",
        "Natural language query from the user"
    )
    .add_object_property(
        "schema",
        "Database schema (tables, columns, relationships)",
        ParametersSchema {
            schema_type: "object".to_string(),
            properties: {
                let mut props = HashMap::new();
                props.insert(
                    "tables".to_string(),
                    PropertySchema {
                        schema_type: "array".to_string(),
                        description: Some("List of table definitions".to_string()),
                        enum_values: None,
                        nested: None,
                    }
                );
                props
            },
            required: vec![],
        }
    )
    .add_object_property(
        "cartridges",
        "Available structured memory cartridges for semantic context",
        ParametersSchema {
            schema_type: "object".to_string(),
            properties: {
                let mut props = HashMap::new();
                props.insert(
                    "entities".to_string(),
                    PropertySchema {
                        schema_type: "array".to_string(),
                        description: Some("Entity cartridge with known entities".to_string()),
                        enum_values: None,
                        nested: None,
                    }
                );
                props.insert(
                    "topics".to_string(),
                    PropertySchema {
                        schema_type: "array".to_string(),
                        description: Some("Topic cartridge with known topics".to_string()),
                        enum_values: None,
                        nested: None,
                    }
                );
                props
            },
            required: vec![],
        }
    )
    .add_enum_property(
        "query_type",
        "Type of query to generate",
        vec![
            Value::String("select".to_string()),
            Value::String("insert".to_string()),
            Value::String("update".to_string()),
            Value::String("delete".to_string()),
        ]
    )
    .add_required("query")
    .add_required("schema")
    .build()
    .into()
}

/// Index recommendation function schema
///
/// Analyzes query patterns and recommends indexes.
pub fn index_recommendation_schema() -> super::FunctionDefinition {
    FunctionSchemaBuilder::new(
        "recommend_indexes",
        "Analyze query patterns and recommend database indexes"
    )
    .add_array_property(
        "queries",
        "List of SQL queries to analyze",
        "string"
    )
    .add_object_property(
        "current_indexes",
        "Currently existing indexes",
        ParametersSchema {
            schema_type: "object".to_string(),
            properties: {
                let mut props = HashMap::new();
                props.insert(
                    "indexes".to_string(),
                    PropertySchema {
                        schema_type: "array".to_string(),
                        description: Some("List of existing indexes".to_string()),
                        enum_values: None,
                        nested: None,
                    }
                );
                props
            },
            required: vec![],
        }
    )
    .add_object_property(
        "table_stats",
        "Table statistics (row counts, sizes)",
        ParametersSchema {
            schema_type: "object".to_string(),
            properties: HashMap::new(),
            required: vec![],
        }
    )
    .add_required("queries")
    .add_required("current_indexes")
    .build()
    .into()
}

/// Performance analysis function schema
///
/// Analyzes database performance and identifies bottlenecks.
pub fn performance_analysis_schema() -> super::FunctionDefinition {
    FunctionSchemaBuilder::new(
        "analyze_performance",
        "Analyze database performance metrics and identify bottlenecks"
    )
    .add_object_property(
        "metrics",
        "Performance metrics (query latency, throughput, cache hit rates)",
        ParametersSchema {
            schema_type: "object".to_string(),
            properties: {
                let mut props = HashMap::new();
                props.insert(
                    "queries".to_string(),
                    PropertySchema {
                        schema_type: "array".to_string(),
                        description: Some("Query execution statistics".to_string()),
                        enum_values: None,
                        nested: None,
                    }
                );
                props.insert(
                    "cache".to_string(),
                    PropertySchema {
                        schema_type: "object".to_string(),
                        description: Some("Cache performance metrics".to_string()),
                        enum_values: None,
                        nested: None,
                    }
                );
                props
            },
            required: vec![],
        }
    )
    .add_string_property(
        "time_range",
        "Time range for analysis (e.g., 'last 1 hour')"
    )
    .add_required("metrics")
    .build()
    .into()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_function_schema_builder() {
        let schema = FunctionSchemaBuilder::new(
            "test_function",
            "Test function description"
        )
        .add_string_property("param1", "First parameter")
        .add_integer_property("param2", "Second parameter")
        .add_required("param1")
        .build();

        assert_eq!(schema.name, "test_function");
        assert_eq!(schema.parameters.properties.len(), 2);
        assert_eq!(schema.parameters.required.len(), 1);
        assert!(schema.parameters.required.contains(&"param1".to_string()));
    }

    #[test]
    fn test_enum_property() {
        let schema = FunctionSchemaBuilder::new(
            "enum_test",
            "Test enum property"
        )
        .add_enum_property(
            "status",
            "Status field",
            vec![
                Value::String("active".to_string()),
                Value::String("inactive".to_string()),
            ]
        )
        .build();

        let prop = &schema.parameters.properties["status"];
        assert_eq!(prop.schema_type, "string");
        assert!(prop.enum_values.is_some());
    }

    #[test]
    fn test_entity_extraction_schema() {
        let schema = entity_extraction_schema();
        assert_eq!(schema.name, "extract_entities");
        assert!(schema.validate_params);
    }

    #[test]
    fn test_query_translation_schema() {
        let schema = query_translation_schema();
        assert_eq!(schema.name, "translate_query");

        // Check that parameters serialize properly
        let json = serde_json::to_string(&schema.parameters).unwrap();
        assert!(json.contains("\"query\""));
        assert!(json.contains("\"schema\""));
    }

    #[test]
    fn test_function_schema_serialization() {
        let schema = FunctionSchemaBuilder::new(
            "test",
            "Test description"
        )
        .add_string_property("arg1", "Argument 1")
        .build();

        let json = serde_json::to_string(&schema).unwrap();
        assert!(json.contains("\"name\":\"test\""));
        assert!(json.contains("\"description\":\"Test description\""));
    }
}
