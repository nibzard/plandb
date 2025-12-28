/**
 * Predefined code examples for the interactive code runner
 *
 * These examples use the simplified put/get syntax for WebAssembly execution.
 * Format: `put:key=value` or `get:key`
 */

export interface CodeExample {
	name: string;
	code: string;
	description: string;
}

export const quickStartExamples: CodeExample[] = [
	{
		name: "Hello World",
		description: "Your first NorthstarDB operations - storing and retrieving values",
		code: `// Store a greeting
put:greeting = Hello, World!

// Store a count
put:count = 42

// Retrieve the values
get:greeting
get:count`,
	},
	{
		name: "User Profile",
		description: "Store and retrieve user profile data",
		code: `// Store user information
put:user:alice:name = Alice Smith
put:user:alice:email = alice@example.com
put:user:alice:role = admin

// Retrieve user data
get:user:alice:name
get:user:alice:email`,
	},
	{
		name: "Counter Pattern",
		description: "Using keys for simple counters",
		code: `// Initialize counters
put:page:views = 0
put:page:likes = 42
put:page:shares = 13

// Read counter values
get:page:likes
get:page:shares`,
	},
	{
		name: "Session Storage",
		description: "Session data management example",
		code: `// Store session data
put:session:1234:user_id = user_abc
put:session:1234:login_time = 2024-01-15T10:30:00Z
put:session:1234:role = editor

// Retrieve session info
get:session:1234:user_id
get:session:1234:role`,
	},
];

export const crudExamples: CodeExample[] = [
	{
		name: "Basic CRUD",
		description: "Create, Read, Update, Delete operations",
		code: `// Create - store new data
put:task:1 = Buy groceries
put:task:2 = Finish report

// Read - retrieve data
get:task:1

// Update - modify existing data
put:task:1 = Buy groceries and cook dinner

// Verify update
get:task:1`,
	},
	{
		name: "Multi-Value Records",
		description: "Storing related data with key prefixes",
		code: `// Store product data
put:product:1001:name = Wireless Mouse
put:product:1001:price = $29.99
put:product:1001:stock = 150

put:product:1002:name = Mechanical Keyboard
put:product:1002:price = $89.99
put:product:1002:stock = 75

// Query product info
get:product:1001:name
get:product:1001:price`,
	},
	{
		name: "Task Queue",
		description: "Simple task management system",
		code: `// Add tasks to queue
put:queue:email:1 = send welcome email to user@example.com
put:queue:email:2 = send password reset to john@doe.com
put:queue:email:3 = send weekly newsletter

// Process tasks
get:queue:email:1
get:queue:email:2`,
	},
	{
		name: "Configuration Storage",
		description: "Application configuration management",
		code: `// Store configuration
put:config:app:debug = true
put:config:app:port = 8080
put:config:app:host = localhost

// Database settings
put:config:db:pool_size = 10
put:config:db:timeout = 30

// Read config
get:config:app:port
get:config:db:pool_size`,
	},
];

export const advancedExamples: CodeExample[] = [
	{
		name: "Time Series Data",
		description: "Storing time-based metrics",
		code: `// Store metrics with timestamps
put:metric:2024-01-15:requests = 15420
put:metric:2024-01-15:errors = 23
put:metric:2024-01-15:latency_ms = 45

put:metric:2024-01-16:requests = 18234
put:metric:2024-01-16:errors = 18
put:metric:2024-01-16:latency_ms = 42

// Query specific day
get:metric:2024-01-15:requests
get:metric:2024-01-15:errors`,
	},
	{
		name: "Cache Implementation",
		description: "Simple caching layer",
		code: `// Cache expensive computations
put:cache:user:123:profile = {"name":"Alice","stats":{...}}
put:cache:user:123:computed_at = 2024-01-15T10:00:00Z

// Cache another user
put:cache:user:456:profile = {"name":"Bob","stats":{...}}
put:cache:user:456:computed_at = 2024-01-15T10:01:00Z

// Retrieve from cache
get:cache:user:123:profile`,
	},
	{
		name: "Rate Limiting",
		description: "Track request counts for rate limiting",
		code: `// Track API requests per user
put:rate_limit:user_alice:requests = 5
put:rate_limit:user_alice:window = 60

put:rate_limit:user_bob:requests = 12
put:rate_limit:user_bob:window = 60

// Check current usage
get:rate_limit:user_alice:requests
get:rate_limit:user_bob:requests`,
	},
];

export const allExamples = {
	quickStart: quickStartExamples,
	crud: crudExamples,
	advanced: advancedExamples,
};

export default allExamples;
