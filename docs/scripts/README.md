# API Documentation Scripts

This directory contains scripts for generating API documentation from Zig source code.

## generate-api-docs.js

Generates HTML documentation from Zig `//!` doc comments and public declarations.

### Usage

```bash
# From the docs directory
npm run docs:api

# Or directly
node scripts/generate-api-docs.js
```

### How it works

1. Uses `gen_docs.zig` wrapper file at project root
2. Runs `zig test -femit-docs` to generate HTML
3. Copies to `docs/public/api` for serving

### Adding new modules

Edit `gen_docs.zig` at the project root to add new modules:

```zig
pub const your_new_module = @import("src/your_new_module.zig");

test {
    _ = your_new_module;
}
```
