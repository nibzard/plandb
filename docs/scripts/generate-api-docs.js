#!/usr/bin/env node

/**
 * Generate API documentation from Zig source files
 *
 * This script:
 * 1. Runs `zig test -femit-docs` using gen_docs.zig wrapper
 * 2. Copies the generated docs to docs/public/api
 * 3. Creates an index page for easy navigation
 */

import { execSync } from 'child_process';
import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

const ROOT_DIR = path.resolve(__dirname, '../..');
const DOCS_DIR = path.join(ROOT_DIR, 'docs');
const API_OUTPUT_DIR = path.join(DOCS_DIR, 'public', 'api');
const GEN_DOCS_FILE = path.join(ROOT_DIR, 'gen_docs.zig');

console.log('Generating API documentation...');

try {
  // Clean previous API docs
  if (fs.existsSync(API_OUTPUT_DIR)) {
    fs.rmSync(API_OUTPUT_DIR, { recursive: true, force: true });
  }
  fs.mkdirSync(API_OUTPUT_DIR, { recursive: true });

  // Check if gen_docs.zig exists
  if (!fs.existsSync(GEN_DOCS_FILE)) {
    console.error(`Error: ${GEN_DOCS_FILE} not found. Please create it first.`);
    process.exit(1);
  }

  // Generate docs using zig test with the gen_docs.zig wrapper
  console.log('Running zig test with -femit-docs...');
  try {
    execSync(
      `zig test "${GEN_DOCS_FILE}" -femit-docs="${API_OUTPUT_DIR}" -fno-emit-bin`,
      {
        cwd: ROOT_DIR,
        stdio: 'inherit',
        timeout: 120000
      }
    );
  } catch (err) {
    // zig test might fail if there are compilation errors
    console.error('Error generating Zig docs:', err.message);
    process.exit(1);
  }

  // Verify docs were generated
  const indexFile = path.join(API_OUTPUT_DIR, 'index.html');
  if (!fs.existsSync(indexFile)) {
    console.error('Error: Zig docs were not generated. Check for compilation errors.');
    process.exit(1);
  }

  // Create a README in the scripts directory
  const readmePath = path.join(__dirname, 'README.md');
  const readmeContent = `# API Documentation Scripts

This directory contains scripts for generating API documentation from Zig source code.

## generate-api-docs.js

Generates HTML documentation from Zig \`//!\` doc comments and public declarations.

### Usage

\`\`\`bash
# From the docs directory
npm run docs:api

# Or directly
node scripts/generate-api-docs.js
\`\`\`

### How it works

1. Uses \`gen_docs.zig\` wrapper file at project root
2. Runs \`zig test -femit-docs\` to generate HTML
3. Copies to \`docs/public/api\` for serving

### Adding new modules

Edit \`gen_docs.zig\` at the project root to add new modules:

\`\`\`zig
pub const your_new_module = @import("src/your_new_module.zig");

test {
    _ = your_new_module;
}
\`\`\`
`;

  fs.writeFileSync(readmePath, readmeContent);

  console.log('\n✅ API documentation generated successfully!');
  console.log('📂 Output directory:', API_OUTPUT_DIR);
  console.log('\n🔍 To view:');
  console.log('  1. Run: cd docs && npm run dev');
  console.log('  2. Visit: http://localhost:4321/api/');
} catch (error) {
  console.error('❌ Error generating API documentation:', error.message);
  process.exit(1);
}
