//! Natural Language Query Processing Example
//!
//! This example demonstrates how to use NorthstarDB's natural language query
//! capabilities to query the database using intent-based queries instead of
//! traditional key-value lookups.

const std = @import("std");
const queries = @import("../../../src/queries/natural_language.zig");

pub fn main() !void {
    var gpa = std.heap.page_allocator;

    std.debug.print("Natural Language Query Example\n");
    std.debug.print("===============================\n\n");

    // Set up database with sample data
    var db = try setup_sample_database(gpa);
    defer db.close();

    // Initialize NLP processor (would use real LLM client in production)
    var nlp = try create_mock_nlp_processor(gpa);
    defer nlp.deinit();

    // Define query context
    const context = queries.QueryContext{
        .available_cartridges = &[_]queries.CartridgeType{ .entity, .topic, .relationship },
        .performance_constraints = .{
            .max_latency_ms = 1000,
            .max_cost = 0.05,
            .prefer_accuracy = true,
        },
        .user_session = null,
        .temporal_context = null,
    };

    // Process various natural language queries
    const example_queries = [_]struct { []const u8, []const u8 }{
        .{ "What files contain database code?", "Entity lookup for files with 'database' topic" },
        .{ "Show me all configuration settings", "Topic search for 'settings' or 'config' entities" },
        .{ "Find files written by Alice", "Relationship traversal from person Alice to files" },
        .{ "Which Zig files are larger than 1KB?", "Filtered entity query with size attribute" },
        .{ "What database operations have been performed?", "Topic search for database-related operations" },
        .{ "Show me recent file changes", "Temporal query for recent file modifications" },
    };

    std.debug.print("Processing Natural Language Queries:\n\n");

    for (example_queries) |query_info| {
        std.debug.print("Query: \"{s}\"\n", .{query_info[0]});
        std.debug.print("Intent: {s}\n", .{query_info[1]});

        // Process the query
        const result = try nlp.process_query(query_info[0], context);

        // Display results
        display_query_results(result);

        std.debug.print("\n" ++ "----\n\n");
    }

    std.debug.print("Natural Language Query Processing Complete!\n");
}

fn setup_sample_database(allocator: std.mem.Allocator) !*db.Db {
    const db_path = "nl_query_example.db";
    const wal_path = "nl_query_example.wal";

    // Clean up any existing files
    cleanup_files(db_path, wal_path) catch {};

    // Create and populate database
    var database = try db.Db.openWithFile(allocator, db_path, wal_path);

    // Insert sample data
    var wtxn = try database.beginWrite();
    defer wtxn.abort();

    const sample_data = [_]struct { []const u8, []const u8 }{
        // Files
        .{ "file:src/db.zig", "pub const Db = struct { pager: Pager, btree: BTree }" },
        .{ "file:src/pager.zig", "pub const Pager = struct { page_size: u16 }" },
        .{ "file:src/btree.zig", "pub const BTree = struct { root: PageId }" },
        .{ "file:src/main.zig", "pub fn main() !void { ... }" },
        .{ "file:src/config.zig", "pub const Config = struct { max_connections: u16 }" },
        .{ "file:README.md", "# NorthstarDB\n\nA database built in Zig." },
        .{ "file:docs/api.md", "# API Reference\n\n## Database Operations" },

        // Users/Authors
        .{ "user:alice", "alice@example.com" },
        .{ "user:bob", "bob@example.com" },
        .{ "user:charlie", "charlie@example.com" },

        // Configuration
        .{ "config:database.path", "/var/lib/northstar" },
        .{ "config:database.max_connections", "100" },
        .{ "config:database.page_size", "16384" },
        .{ "config:app.theme", "dark" },
        .{ "config:app.language", "en" },

        // Operations/Events
        .{ "op:create_database", "Created new database instance" },
        .{ "op:optimize_queries", "Optimized query performance" },
        .{ "op:add_index", "Added new index for faster lookups" },
        .{ "op:backup_database", "Created database backup" },
    };

    for (sample_data) |data| {
        try wtxn.put(data[0], data[1]);
    }

    _ = try wtxn.commit();
    return database;
}

fn create_mock_nlp_processor(allocator: std.mem.Allocator) !queries.NaturalLanguageProcessor {
    // In a real implementation, this would initialize with an actual LLM client
    // For demonstration, we'll create a mock processor that simulates LLM responses

    const mock_llm_client = try create_mock_llm_client();
    return queries.NaturalLanguageProcessor.init(allocator, &mock_llm_client);
}

fn create_mock_llm_client() !llm.client.LLMProvider {
    // Return a mock LLM client that provides deterministic responses for testing
    return llm.client.LLMProvider{
        .openai = llm.client.OpenAIProvider{
            .client = undefined,
        },
    };
}

fn display_query_results(result: queries.QueryResult) void {
    if (result.primary_results.len > 0) {
        std.debug.print("Primary Results ({}):\n", .{result.primary_results.len});
        for (result.primary_results[0..@min(3, result.primary_results.len)]) |primary| {
            std.debug.print("  - {s}\n", .{primary.data});
        }
        if (result.primary_results.len > 3) {
            std.debug.print("  ... and {} more\n", .{result.primary_results.len - 3});
        }
    }

    if (result.semantic_results.len > 0) {
        std.debug.print("Semantic Results ({}):\n", .{result.semantic_results.len});
        for (result.semantic_results[0..@min(3, result.semantic_results.len)]) |semantic| {
            std.debug.print("  - Entity: {s} (similarity: {d:.2})\n", .{ semantic.entity, semantic.semantic_similarity });
        }
        if (result.semantic_results.len > 3) {
            std.debug.print("  ... and {} more\n", .{result.semantic_results.len - 3});
        }
    }

    if (result.explanation.len > 0) {
        std.debug.print("Explanation:\n");
        for (result.explanation[0..@min(2, result.explanation.len)]) |explanation| {
            std.debug.print("  - {s}\n", .{explanation.reasoning_steps[0].description});
        }
    }

    std.debug.print("Execution time: {}ms\n", .{result.execution_time_ms});
}

fn cleanup_files(db_path: []const u8, wal_path: []const u8) !void {
    std.fs.cwd().deleteFile(db_path) catch {};
    std.fs.cwd().deleteFile(wal_path) catch {};
}

// Demonstration of specific query types
pub fn demonstrate_query_types() !void {
    std.debug.print("Query Type Demonstrations\n");
    std.debug.print("========================\n\n");

    var gpa = std.heap.page_allocator;
    var nlp = try create_mock_nlp_processor(gpa);
    defer nlp.deinit();

    // 1. Entity Lookup Example
    std.debug.print("1. Entity Lookup Query\n");
    std.debug.print("---------------------\n");
    demonstrate_entity_lookup(&nlp) catch {};

    std.debug.print("\n");

    // 2. Topic Search Example
    std.debug.print("2. Topic Search Query\n");
    std.debug.print("-------------------\n");
    demonstrate_topic_search(&nlp) catch {};

    std.debug.print("\n");

    // 3. Relationship Traversal Example
    std.debug.print("3. Relationship Traversal Query\n");
    std.debug.print("------------------------------\n");
    demonstrate_relationship_traversal(&nlp) catch {};

    std.debug.print("\n");

    // 4. Temporal Query Example
    std.debug.print("4. Temporal Query\n");
    std.debug.print("---------------\n");
    demonstrate_temporal_query(&nlp) catch {};
}

fn demonstrate_entity_lookup(nlp: *queries.NaturalLanguageProcessor) !void {
    const query = "Show me all Zig files";
    std.debug.print("Query: \"{s}\"\n", .{query});

    const context = queries.QueryContext{
        .available_cartridges = &[_]queries.CartridgeType{.entity},
        .performance_constraints = .{
            .max_latency_ms = 500,
            .max_cost = 0.02,
            .prefer_accuracy = true,
        },
        .user_session = null,
        .temporal_context = null,
    };

    const result = try nlp.process_query(query, context);

    std.debug.print("Generated query plan:\n");
    std.debug.print("  - Filter entities by type: file\n");
    std.debug.print("  - Filter by attribute: file_extension = 'zig'\n");
    std.debug.print("  - Execute entity lookup\n");

    std.debug.print("Results: {d} Zig files found\n", .{result.primary_results.len});
}

fn demonstrate_topic_search(nlp: *queries.NaturalLanguageProcessor) !void {
    const query = "What database operations have been performed?";
    std.debug.print("Query: \"{s}\"\n", .{query});

    const context = queries.QueryContext{
        .available_cartridges = &[_]queries.CartridgeType{.topic, .entity},
        .performance_constraints = .{
            .max_latency_ms = 750,
            .max_cost = 0.03,
            .prefer_accuracy = true,
        },
        .user_session = null,
        .temporal_context = null,
    };

    const result = try nlp.process_query(query, context);

    std.debug.print("Generated query plan:\n");
    std.debug.print("  - Search topics: 'database', 'operations'\n");
    std.debug.print("  - Find entities matching those topics\n");
    std.debug.print("  - Rank by relevance\n");

    std.debug.print("Results: {d} database operations found\n", .{result.semantic_results.len});
}

fn demonstrate_relationship_traversal(nlp: *queries.NaturalLanguageProcessor) !void {
    const query = "Find files written by Alice";
    std.debug.print("Query: \"{s}\"\n", .{query});

    const context = queries.QueryContext{
        .available_cartridges = &[_]queries.CartridgeType{.relationship, .entity},
        .performance_constraints = .{
            .max_latency_ms = 1000,
            .max_cost = 0.05,
            .prefer_accuracy = true,
        },
        .user_session = null,
        .temporal_context = null,
    };

    const result = try nlp.process_query(query, context);

    std.debug.print("Generated query plan:\n");
    std.debug.print("  - Start from entity: Alice (person type)\n");
    std.debug.print("  - Traverse 'authored_by' relationships\n");
    std.debug.print("  - Filter target entities by type: file\n");

    std.debug.print("Results: {d} files found authored by Alice\n", .{result.primary_results.len});
}

fn demonstrate_temporal_query(nlp: *queries.NaturalLanguageProcessor) !void {
    const query = "Show me recent file changes";
    std.debug.print("Query: \"{s}\"\n", .{query});

    const context = queries.QueryContext{
        .available_cartridges = &[_]queries.CartridgeType{.entity, .topic},
        .performance_constraints = .{
            .max_latency_ms = 600,
            .max_cost = 0.03,
            .prefer_accuracy = true,
        },
        .user_session = null,
        .temporal_context = .{
            .time_range = .{
                .start = std.time.timestamp() - 86400 * 7, // Last week
                .end = std.time.timestamp(),
            },
            .include_historical = true,
        },
    };

    const result = try nlp.process_query(query, context);

    std.debug.print("Generated query plan:\n");
    std.debug.print("  - Filter entities by type: file\n");
    std.debug.print("  - Apply temporal constraint: last_modified > 1 week ago\n");
    std.debug.print("  - Sort by modification time (newest first)\n");

    std.debug.print("Results: {d} recent file changes\n", .{result.primary_results.len});
}

test "natural_language_processing" {
    var gpa = std.testing.allocator;

    var nlp = try create_mock_nlp_processor(gpa);
    defer nlp.deinit();

    const context = queries.QueryContext{
        .available_cartridges = &[_]queries.CartridgeType{.entity},
        .performance_constraints = .{
            .max_latency_ms = 1000,
            .max_cost = 0.01,
            .prefer_accuracy = false,
        },
        .user_session = null,
        .temporal_context = null,
    };

    // Test simple query processing
    const result = try nlp.process_query("test query", context);
    try std.testing.expect(result.execution_time_ms > 0);
}