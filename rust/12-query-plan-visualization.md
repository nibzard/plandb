# Query Plan Visualization

## Purpose

Query Plan Visualization provides comprehensive visibility into how queries are executed within the database. This module enables developers, database administrators, and automated systems to understand query execution strategies, identify performance bottlenecks, and optimize query patterns. The visualization layer transforms abstract query execution plans into human-readable formats including text representations, tree structures, and detailed metric breakdowns.

## Types

### PlanNode

**Description**: Represents a single operation within a query execution plan. Each node corresponds to a specific operation such as scanning a table, accessing an index, filtering results, joining data, or aggregating values. Nodes form a tree structure where leaf nodes perform data access and internal nodes transform data.

**Fields**:
- node_id: u64 - Unique identifier for this node within the plan
- node_type: PlanNodeType - The type of operation this node performs
- estimated_cost: f64 - Query optimizer's estimated cost for this operation
- actual_metrics: ExecutionMetrics - Actual runtime metrics collected during execution
- children: Vec<PlanNode> - Child nodes that provide input to this operation
- predicates: Vec<Predicate> - Filters or conditions applied at this node
- table_info: Option<TableInfo> - Metadata for table access operations
- index_info: Option<IndexInfo> - Metadata for index usage operations

**Invariants**:
- node_id must be unique within the query plan
- estimated_cost is non-negative
- children vector order is significant (left to right execution order)
- At least one of table_info or index_info is present for access nodes

### PlanNodeType

**Description**: Enumeration of all possible operation types in a query execution plan. Each variant represents a distinct class of database operation with specific performance characteristics and resource requirements.

**Variants**:
- TableScan - Sequential scan of all rows in a table
- IndexScan - Ordered scan using an index with optional range bounds
- IndexSeek - Direct lookup by index key (single row or few rows)
- Filter - Application of predicate conditions to filter rows
- NestedLoopJoin - Join using nested loop algorithm
- HashJoin - Join using hash-based aggregation
- MergeJoin - Join using sorted merge algorithm
- Aggregate - Grouping and aggregation operations
- Sort - Explicit sorting operation
- Limit - Restriction of result set size
- Projection - Selection and transformation of columns
- Union - Combination of result sets
- Intersect - Intersection of result sets
- Except - Set difference operation

### ExecutionMetrics

**Description**: Runtime statistics collected during query execution. These metrics provide ground truth about actual performance versus optimizer estimates.

**Fields**:
- rows_produced: u64 - Number of rows output by this node
- rows_read: u64 - Number of rows read from child nodes
- execution_time_ms: f64 - Wall-clock time spent in this node
- cpu_time_ms: f64 - CPU time consumed by this node
- blocks_read: u64 - Number of disk blocks or pages read
- blocks_cache_hit: u64 - Number of blocks served from cache
- memory_bytes: u64 - Peak memory usage during execution
- spill_bytes: u64 - Bytes written to disk due to memory pressure

**Invariants**:
- All counter values are non-negative
- rows_produced is less than or equal to rows_read
- blocks_cache_hit is less than or equal to blocks_read
- execution_time_ms is greater than or equal to cpu_time_ms

### Predicate

**Description**: Represents a filter condition or predicate applied to data. Predicates push filters down to the lowest possible node in the plan to reduce data flow.

**Fields**:
- column_name: String - Name of the column being filtered
- operator: PredicateOperator - Comparison or logical operator
- value: LiteralValue - Constant value being compared against
- is_sargable: bool - Whether predicate can use an index (search argument able)

**Invariants**:
- column_name must reference a valid column in the input schema
- is_sargable being true implies an index exists on this column

### PredicateOperator

**Description**: Type of comparison or logical operation in a predicate.

**Variants**:
- Equal - Exact equality match (=)
- NotEqual - Inequality match (!=)
- LessThan - Strict less than (<)
- LessThanOrEqual - Less than or equal (<=)
- GreaterThan - Strict greater than (>)
- GreaterThanOrEqual - Greater than or equal (>=)
- Like - Pattern matching with wildcards
- In - Membership test in a set
- IsNull - Test for null values
- Between - Range test (inclusive lower and upper bounds)
- And - Logical conjunction of two predicates
- Or - Logical disjunction of two predicates
- Not - Logical negation of a predicate

### TableInfo

**Description**: Metadata about table access operations.

**Fields**:
- table_name: String - Name of the table being accessed
- table_type: TableType - Type of table (heap, B+tree, etc.)
- estimated_rows: u64 - Optimizer's estimate of rows to be read
- actual_rows: u64 - Actual rows read during execution
- is_sequential: bool - Whether access is sequential or random

### IndexInfo

**Description**: Metadata about index usage during query execution.

**Fields**:
- index_name: String - Name of the index being used
- index_type: IndexType - Type of index (B+tree, hash, etc.)
- index_columns: Vec<String> - Columns comprising the index key
- is_primary: bool - Whether this is the primary key index
- is_unique: bool - Whether index enforces uniqueness
- is_covering: bool - Whether index covers all query columns (no table access needed)
- seek_type: IndexSeekType - Type of index operation performed
- rows_estimated: u64 - Estimated rows to be read from index
- rows_actual: u64 - Actual rows read from index
- index_depth: u32 - Number of levels traversed in index

### IndexSeekType

**Description**: Describes how an index is accessed during query execution.

**Variants**:
- PointLookup - Direct lookup by exact key (most efficient)
- RangeScan - Scan over a range of keys
- PrefixScan - Scan using key prefix (partial key match)
- FullScan - Scan entire index (least efficient)
- MultiSeek - Multiple point lookups combined

### QueryPlan

**Description**: Complete query execution plan representing the entire strategy for executing a query. Contains metadata about the query and the root node of the plan tree.

**Fields**:
- query_id: u64 - Unique identifier for the query
- query_text: String - Original SQL or query language text
- plan_tree: PlanNode - Root node of the plan tree
- plan_type: PlanType - Whether plan is estimated or actual
- total_cost: f64 - Optimizer's total estimated cost
- total_time_ms: f64 - Total actual execution time
- created_at: Timestamp - When the plan was generated
- optimization_level: OptimizationLevel - Aggressiveness of optimization applied

### PlanType

**Description**: Distinguishes between estimated plans (optimizer predictions without execution) and actual plans (post-execution with real metrics).

**Variants**:
- Estimated - Plan generated by optimizer without execution
- Actual - Plan populated with real execution metrics
- Hybrid - Partially executed plan with some estimated and some actual metrics

### OptimizationLevel

**Description**: Controls how much effort the optimizer spends on plan generation.

**Variants**:
- Minimal - Fast planning with minimal optimization
- Standard - Balance between planning time and plan quality
- Full - Exhaustive search for optimal plan (expensive)
- Adaptive - Dynamically adjust based on query complexity

### PlanTree

**Description**: Tree structure representation of a query plan with parent-child relationships and depth information for visualization.

**Fields**:
- root: Box<PlanNode> - Root node of the plan tree
- depth: u32 - Maximum depth of the tree
- node_count: u32 - Total number of nodes in the tree
- max_branching: u32 - Maximum number of children at any node

### VisualizationFormat

**Description**: Defines output formats for query plan visualization.

**Variants**:
- Text - Plain text hierarchical representation
- Json - Structured JSON format for programmatic consumption
- Dot - Graphviz DOT format for graphical rendering
- Html - Interactive HTML visualization with collapsible nodes
- Markdown - Markdown table format for documentation

## Functions

### explain_plan(query: &str) -> Result<QueryPlan>

**Purpose**: Generate an estimated query execution plan without executing the query. Used for understanding how the optimizer will approach a query.

**Parameters**:
- query: String reference to the query text to be analyzed

**Returns**: QueryPlan structure containing the optimizer's planned execution strategy

**Algorithm**:
1. Parse the query text into an abstract syntax tree
2. Validate the query against schema metadata
3. Generate candidate execution plans using rewrite rules
4. Apply cost estimation model to each candidate plan
5. Select the lowest-cost plan using the optimization strategy
6. Construct the PlanNode tree with estimated costs
7. Return the complete QueryPlan structure

**Error Conditions**:
- ParseError: Query text contains syntax errors
- ValidationError: Query references non-existent tables or columns
- PlanningError: Optimizer cannot generate a valid plan

**Concurrency**: Read-only operation, safe for concurrent calls

### visualize_plan_text(plan: &QueryPlan) -> String

**Purpose**: Convert a query plan into a human-readable text format with hierarchical indentation showing parent-child relationships.

**Parameters**:
- plan: Reference to the query plan to visualize

**Returns**: Multi-line string with formatted text representation

**Algorithm**:
1. Start at the root node with zero indentation
2. Print node type and key metrics on current line
3. For each child node, recurse with increased indentation
4. Include actual metrics if plan type is Actual, otherwise show estimates
5. Format duration in milliseconds, row counts with comma separators
6. Show index usage information for index scan nodes
7. Display predicate information for filter nodes

**Output Format**:
```
TableScan on users (estimated_rows=100000, actual_rows=100000, time=45.2ms)
  Filter: age >= 25 AND age < 35 (rows_produced=30000, time=12.1ms)
    IndexSeek on idx_users_age (index_type=btree, rows=30000, depth=3)
  Projection: id, name, email (rows_produced=30000)
```

**Concurrency**: Read-only operation, safe for concurrent calls

### visualize_plan_json(plan: &QueryPlan) -> String

**Purpose**: Serialize a query plan to JSON format for programmatic consumption by monitoring tools, logging systems, or web interfaces.

**Parameters**:
- plan: Reference to the query plan to serialize

**Returns**: JSON string representing the complete plan structure

**Algorithm**:
1. Create a JSON object with query metadata (id, text, timing)
2. Recursively serialize each node to a JSON object
3. Include all node fields: type, costs, metrics, children
4. Serialize child nodes as nested array within parent node
5. Convert enums to string representations
6. Format timestamps in ISO 8601 format
7. Return compact JSON string

**JSON Structure**:
```json
{
  "query_id": "12345",
  "query_text": "SELECT * FROM users WHERE age > 25",
  "plan_type": "actual",
  "total_time_ms": 45.2,
  "root_node": {
    "node_id": 1,
    "node_type": "TableScan",
    "estimated_cost": 1000.0,
    "actual_metrics": {
      "rows_produced": 30000,
      "execution_time_ms": 45.2
    },
    "children": []
  }
}
```

**Concurrency**: Read-only operation, safe for concurrent calls

### visualize_plan_dot(plan: &QueryPlan) -> String

**Purpose**: Generate Graphviz DOT format for rendering query plans as graphical tree diagrams using tools like Graphviz or online viewers.

**Parameters**:
- plan: Reference to the query plan to visualize

**Returns**: DOT language string representing the plan as a directed graph

**Algorithm**:
1. Create DOT digraph declaration with graph attributes
2. Assign unique identifier to each node (node_id)
3. For each node, create a node declaration with label containing:
   - Node type as primary label
   - Key metrics in formatted text (rows, time)
   - Index information if applicable
4. For each parent-child relationship, create an edge declaration
5. Style nodes by type (scans in blue, joins in green, filters in yellow)
6. Add edge labels showing data flow (row counts)
7. Return complete DOT script

**DOT Structure**:
```
digraph QueryPlan {
  node1 [label="TableScan\\nrows=100000\\ntime=45.2ms", shape=box, color=blue];
  node2 [label="Filter\\nrows=30000", shape=diamond, color=yellow];
  node1 -> node2 [label="100000 rows"];
}
```

**Concurrency**: Read-only operation, safe for concurrent calls

### visualize_plan_html(plan: &QueryPlan) -> String

**Purpose**: Generate interactive HTML visualization with collapsible nodes, hover tooltips showing detailed metrics, and color coding for easy analysis.

**Parameters**:
- plan: Reference to the query plan to visualize

**Returns**: Complete HTML document with embedded CSS and JavaScript

**Algorithm**:
1. Create HTML document structure with head and body sections
2. Embed CSS for styling nodes, edges, and layout
3. Generate HTML elements for each node with:
   - Collapsible sections using details/summary elements
   - Tooltip spans with detailed metrics on hover
   - Color coding by node type (CSS classes)
4. Include JavaScript for interactive features:
   - Expand/collapse all functionality
   - Search for specific node types
   - Highlight expensive execution paths
5. Recursively build nested HTML structure for child nodes
6. Add legend explaining node type colors
7. Return complete, self-contained HTML document

**HTML Features**:
- Expandable tree structure with show/hide buttons
- Hover tooltips display full metric details
- Color-coded nodes by operation type
- Highlight nodes with high cost or poor performance
- Search and filter capabilities
- Export to image or PDF buttons

**Concurrency**: Read-only operation, safe for concurrent calls

### calculate_plan_depth(plan: &QueryPlan) -> u32

**Purpose**: Calculate the maximum depth of the query plan tree, indicating plan complexity and the number of operation layers.

**Parameters**:
- plan: Reference to the query plan

**Returns**: Depth value where 1 means only root node, greater values indicate deeper trees

**Algorithm**:
1. Start at root node with depth of 1
2. For each child of current node, recursively calculate depth
3. Return maximum child depth plus 1
4. If no children, return 1

**Concurrency**: Read-only operation, safe for concurrent calls

### find_most_expensive_node(plan: &QueryPlan, metric: CostMetric) -> Option<&PlanNode>

**Purpose**: Identify the node with the highest cost according to a specific metric, useful for focusing optimization efforts.

**Parameters**:
- plan: Reference to the query plan
- metric: Which cost metric to compare (ExecutionTime, CpuTime, BlocksRead, RowsRead, MemoryBytes)

**Returns**: Optional reference to the most expensive node, or None if plan is empty

**Algorithm**:
1. Initialize tracking variables for maximum value and node reference
2. Traverse plan tree in depth-first order
3. For each node, extract the specified metric value
4. If metric value exceeds current maximum, update tracking
5. Recursively process all child nodes
6. Return reference to node with highest metric value

**CostMetric Options**:
- ExecutionTime - Wall-clock time (ms)
- CpuTime - CPU consumption (ms)
- BlocksRead - Disk I/O operations
- RowsRead - Data volume processed
- MemoryBytes - Peak memory usage

**Concurrency**: Read-only operation, safe for concurrent calls

### compare_plans(before: &QueryPlan, after: &QueryPlan) -> PlanComparison

**Purpose**: Compare two query plans (typically before and after optimization) to quantify improvements and identify structural changes.

**Parameters**:
- before: Original query plan
- after: Optimized or alternative query plan

**Returns**: PlanComparison structure highlighting differences

**Algorithm**:
1. Verify both plans are for the same query (compare query_text)
2. Compare total costs and times, calculate percentage improvements
3. Compare tree structures (depth, node count, branching factor)
4. Identify nodes that exist in only one plan
5. Match nodes by operation type and compare metrics
6. Detect index usage changes (scan vs seek, different indexes)
7. Identify join strategy changes (nested loop vs hash vs merge)
8. Build comparison summary with key insights

**Concurrency**: Read-only operation, safe for concurrent calls

### PlanComparison

**Description**: Summary of differences between two query plans.

**Fields**:
- cost_improvement_pct: f64 - Percentage reduction in total cost
- time_improvement_pct: f64 - Percentage reduction in execution time
- structural_change: StructuralChangeType - How the plan structure changed
- index_changes: Vec<IndexChange> - Differences in index usage
- join_changes: Vec<JoinChange> - Differences in join strategies
- insights: Vec<String> - Human-readable observations about improvements

### StructuralChangeType

**Description**: Categorizes the type of structural difference between plans.

**Variants**:
- Identical - Plans are structurally the same
- Simplified - After plan has fewer nodes or less depth
- Complex - After plan has more nodes (possible for complex queries)
- Restructured - Same complexity but different organization

### IndexChange

**Description**: Describes a change in index usage between two plans.

**Fields**:
- table_name: String - Table whose index usage changed
- before_index: Option<String> - Index used in before plan
- after_index: Option<String> - Index used in after plan
- before_type: IndexSeekType - Type of index operation before
- after_type: IndexSeekType - Type of index operation after
- impact: ChangeImpact - Whether change improved, degraded, or neutral

### ChangeImpact

**Description**: Qualitative assessment of a plan change.

**Variants**:
- Improved - Change resulted in better performance
- Degraded - Change resulted in worse performance
- Neutral - No significant performance impact

## Invariants

- Every query plan has exactly one root node
- Node identifiers are unique within a plan
- Plan trees are acyclic (no circular dependencies)
- Actual execution metrics can only be present for plans that have been executed
- Estimated costs are always present for both estimated and actual plans
- Child nodes are always executed before their parent (data flows upward)

## Dependencies

- **Uses**: Query parser, Query optimizer, Schema metadata, Statistics collection
- **Used by**: Database CLI, Monitoring tools, Performance analysis utilities, Web admin interface

## Rust Implementation Guidance

### Module Structure

The Rust module should be organized as follows:

```
northstar-core/src/query_plan/
├── mod.rs              - Module exports and public API
├── types.rs            - PlanNode, PlanNodeType, ExecutionMetrics, etc.
├── explain.rs          - explain_plan function and planning logic
├── visualize.rs        - All visualization format generators
├── compare.rs          - Plan comparison logic
└── error.rs            - Plan-specific error types
```

### Type Definitions

- **PlanNode**: Should use struct with Vec for children, Box not needed due to Vec ownership
- **PlanNodeType**: Should be represented as enum with variants
- **ExecutionMetrics**: struct with u64 counters and f64 durations
- **Choice**: Use Arc<str> instead of String for column names and identifiers to reduce allocations

### Concurrency

- **Pattern**: QueryPlan should be immutable after creation, allowing safe concurrent reads
- **Pattern**: Use Arc for sharing QueryPlan across threads without cloning
- **Pattern**: Visualization functions should accept &QueryPlan references and return owned Strings

### Key Decisions

- **JSON Library**: Use serde_json for serialization (already a dependency)
- **HTML Generation**: Build string directly rather than template engine for zero-dependency approach
- **DOT Format**: Generate string directly without external graphviz library binding
- **Plan Comparison**: Create new structure rather than modifying input plans

### Implementation Notes

1. **Step 1: Define core types** in types.rs
   - Start with PlanNodeType enum and ExecutionMetrics struct
   - Implement Display trait for PlanNodeType for text formatting
   - Add Serialize/Deserialize derives for JSON support

2. **Step 2: Implement explain_plan** in explain.rs
   - Integrate with existing query parser and optimizer
   - Generate plan tree from optimizer output
   - Populate estimated costs from optimizer cost model

3. **Step 3: Build text visualization** in visualize.rs
   - Use recursive function with indentation level parameter
   - Implement clean formatting with consistent alignment
   - Handle both estimated and actual metric display

4. **Step 4: Add JSON serialization**
   - Leverage serde derive macros on all types
   - Use serde_json::to_string for compact JSON output
   - Consider serde_json::to_string_pretty for debug mode

5. **Step 5: Implement DOT generation**
   - Follow Graphviz DOT language syntax
   - Use consistent node naming scheme
   - Apply color attributes based on node type

6. **Step 6: Create HTML visualization**
   - Use embedded CSS within <style> tags
   - Leverage HTML5 details/summary for collapsible sections
   - Include vanilla JavaScript (no framework dependencies)
   - Make self-contained HTML file (no external resources)

7. **Step 7: Build comparison logic** in compare.rs
   - Match nodes by type and approximate position in tree
   - Calculate percentage improvements carefully (handle divide by zero)
   - Generate human-readable insights using string templates

### Testing Strategy

**Unit tests needed for**:
- Text visualization formatting with various plan structures
- JSON serialization and deserialization round-trips
- DOT format validity (parse with external DOT validator)
- Plan depth calculation on complex trees
- Most expensive node finding with each cost metric
- Plan comparison with various improvement scenarios

**Property tests for**:
- Plan depth is consistent for any traversal order
- Most expensive node actually has maximum metric value
- Text visualization output contains all node information
- JSON serialization is lossless (deserializes to equal value)

**Integration scenarios**:
- Generate real plans from test queries
- Compare plans before and after index creation
- Validate actual metrics match execution statistics
- Test HTML interactivity in browser environment

### Performance Considerations

- Visualization generation is linear in plan tree size
- For large plans (>1000 nodes), consider summarization or truncation
- HTML generation with heavy JavaScript should be cached
- JSON serialization cost increases with plan complexity
- Text format should be optimized for terminal width (80-120 characters)

### Error Handling

- QueryParseError for invalid query syntax
- PlanGenerationError for optimizer failures
- VisualizationError for rendering issues (should not occur)
- All errors implement std::error::Error and provide context
- Use thiserror crate for clean error definitions
