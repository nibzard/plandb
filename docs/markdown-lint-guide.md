# Documentation Linting Guide

## Overview

NorthstarDB uses automated markdown linting to ensure consistency and quality across all documentation files. This guide explains how to use the linter.

## Installation

```bash
npm install -g markdownlint-cli
```

## Running the Linter

### Lint all documentation files:

```bash
markdownlint "docs/src/content/docs/**/*.md" \
            "docs/src/content/docs/**/*.mdx" \
            "docs/adr/*.md" \
            "spec/**/*.md" \
            "*.md" \
            --config ".markdownlint.jsonc"
```

### Lint specific file:

```bash
markdownlint path/to/file.md --config ".markdownlint.jsonc"
```

## Fixing Issues

### Automatic fixes

Some issues can be fixed automatically:

```bash
markdownlint "docs/**/*.md" --fix --config ".markdownlint.jsonc"
```

### Common Issues

1. **Hard tabs (MD010)**: Replace tabs with spaces
2. **Line length (MD013)**: Keep lines under 120 characters
3. **Ordered list prefix (MD029)**: Use `1.` for all ordered list items
4. **Code block language (MD040)**: Specify language: ` ```zig ` instead of ` ``` `
5. **Trailing whitespace (MD009)**: Remove trailing spaces

## Configuration

See `.markdownlint.jsonc` for the complete rule configuration.

## CI/CD

The linting runs automatically on:
- Push to `main` branch
- Pull requests

PRs will fail if critical linting errors are found.
