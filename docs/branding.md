# Branding Guidelines

This document defines NorthstarDB's visual identity and communication standards.

## Logo

### Primary Logo

The NorthstarDB logo combines:
- **Polaris (North Star)**: Guiding light, reliability, navigation
- **Database icon**: Data storage and structure

**Specifications**:
- Format: SVG (scalable), PNG (raster)
- Variants: Full color, monochrome, light/dark mode
- Minimum size: 32px height (digital), 1 inch (print)

**Usage**:
- **Do** use on official documentation, website, releases
- **Don't** modify colors, stretch, or add effects
- **Don't** use in a way that implies endorsement

### Logo Variants

| Variant | Use Case |
|---------|----------|
| Full color | Primary branding, headers |
| Monochrome | Single-color printing, icons |
| Dark mode | Dark backgrounds, terminal themes |

*Logo files are available in `/assets/logo/`*

## Color Palette

### Primary Colors

| Color | Hex | Usage |
|-------|-----|-------|
| **North Star Blue** | `#3B82F6` | Primary actions, links, accents |
| **Deep Space** | `#0F172A` | Navigation, headers, code blocks |
| **Starlight** | `#F8FAFC` | Backgrounds, light mode |

### Secondary Colors

| Color | Hex | Usage |
|-------|-----|-------|
| **Success Green** | `#10B981` | Success states, passed tests |
| **Error Red** | `#EF4444` | Errors, failures, warnings |
| **Warning Amber** | `#F59E0B` | Warnings, deprecations |
| **Info Cyan** | `#06B6D4` | Information, notes |

### Semantic Colors (Terminal)

| Element | Hex | Purpose |
|---------|-----|---------|
| Zig Keywords | `#C586C0` | Syntax highlighting |
| String Literals | `#CE9178` | Syntax highlighting |
| Comments | `#6A9955` | Syntax highlighting |

## Typography

### Fonts

**Headings**: Inter, system-ui, sans-serif
- Regular: 400
- Medium: 500
- Bold: 700

**Body**: Inter, system-ui, sans-serif
- Regular: 400
- Line height: 1.6

**Code/Monospace**: 'JetBrains Mono', 'Fira Code', 'Cascadia Code', monospace
- Regular: 400
- Tabular figures for alignment

### Type Scale

| Element | Size | Weight | Usage |
|---------|------|--------|-------|
| H1 | 2.5rem (40px) | 700 | Page titles |
| H2 | 2rem (32px) | 600 | Section headers |
| H3 | 1.5rem (24px) | 600 | Subsections |
| Body | 1rem (16px) | 400 | Paragraphs |
| Small | 0.875rem (14px) | 400 | Captions, metadata |
| Code | 0.875rem (14px) | 400 | Inline code |

## Voice and Tone

### Principles

1. **Clear over clever**: Prioritize understanding
2. **Confident but humble**: Admit when we're learning
3. **Developer-first**: Speak the user's language
4. **Action-oriented**: Tell them what to do, not what not to do

### Guidelines

| Context | Tone | Example |
|---------|------|---------|
| Tutorials | Encouraging, step-by-step | "Let's create a new database..." |
| API Reference | Precise, concise | "Inserts a key-value pair..." |
| Error Messages | Helpful, actionable | "Expected type `[]const u8`, found `int`" |
| Release Notes | Celebratory, informative | "Added 2x faster range queries..." |

### Do's and Don'ts

**Do**:
- Use active voice ("Open the file" not "The file should be opened")
- Be specific ("Returns the page ID" not "Returns info")
- Use we/you for connection ("You can now query...")
- Include examples for complex concepts

**Don't**:
- Use jargon without explanation
- Be wordy or passive
- Use exclamation points excessively (max 1 per section)
- Assume knowledge of internal implementation

## Terminology

### Standard Terms

| Term | Definition | Usage |
|------|------------|-------|
| **NorthstarDB** | The database project | Always one word, capitalized DB |
| **Zig** | The programming language | Capitalized |
| **B+tree** | The index structure | Plus sign, no space |
| **Transaction** | ACID operation | Lowercase unless title |
| **MVCC** | Multi-version concurrency control | Always uppercase |
| **Cartridge** | Structured memory unit | Phase 7 feature |
| **Snapshot** | Consistent read view | Lowercase unless title |

### Code-Related Terms

- **Function names**: `Code font` with parentheses: `openDb()`
- **File names**: `Code font`: `src/db.zig`
- **CLI commands**: `Code font` with backticks: `zig build run`
- **Command-line flags**: Use `--flag` format with backticks

### Capitalization

- **Headers**: Title Case ("Getting Started")
- **Navigation**: Sentence case ("API reference")
- **Buttons**: Title case for multi-word ("Create Database"), lowercase for single-word ("Save")

## Spacing and Layout

### Margins and Padding

| Context | Size |
|---------|------|
| Page margins | 2rem (32px) |
| Section spacing | 3rem (48px) |
| Paragraph spacing | 1rem (16px) |
| Code block margin | 1.5rem (24px) |

### Code Blocks

```
- Use syntax highlighting for Zig
- Show language identifier: ```zig
- Include file name for long examples: <!-- src/db.zig -->
- Maximum width: 80 characters for readability
```

### Diagrams

- Use Mermaid for flowcharts and sequence diagrams
- Maintain 4:3 aspect ratio
- Alt text for accessibility
- Source code in `docs/diagrams/`

## Documentation Structure

### Page Hierarchy

```
docs/
├── README.md (Overview)
├── getting-started/
│   ├── installation.md
│   └── quickstart.md
├── api/
│   └── reference.md
├── guides/
│   └── transactions.md
└── architecture/
    └── overview.md
```

### Front Matter

Every page should include:

```markdown
---
title: Page Title
description: One-line summary for SEO
sidebar: main
order: 10
---
```

## Asset Guidelines

### Icons

- Use [Heroicons](https://heroicons.com/) or [Lucide](https://lucide.dev/)
- SVG format with inline `stroke` and `fill`
- Consistent 2px stroke width
- Minimum 24x24px for visibility

### Images

- Format: WebP (photos), PNG (graphics), SVG (diagrams)
- Max size: 500KB per image
- Alt text required
- Responsive: Include srcset for multiple sizes

## Code Examples

### Style

```zig
// 1. Use descriptive variable names
const user_database = try db.open("users.db");

// 2. Add comments for non-obvious logic
// Allocate page in the free list before use
const page_id = try pager.allocatePage();

// 3. Handle errors explicitly
const txn = try db.beginWriteTxn();
defer txn.commit() catch |err| {
    std.log.err("Commit failed: {}", .{err});
    return err;
};
```

### Length

- **Inline**: Max 80 characters (fits terminal)
- **Blocks**: Max 20 lines for examples (split if longer)
- **Files**: Full examples in `examples/` directory

## Accessibility

### Color Contrast

- Text: WCAG AA (4.5:1 minimum)
- Large text: WCAG AA (3:1 minimum)
- Interactive elements: WCAG AAA (7:1 minimum)

### Screen Readers

- Descriptive link text (not "click here")
- Alt text for images
- Semantic HTML (proper heading hierarchy)
- ARIA labels for interactive elements

## Templates

### README Header

```markdown
# NorthstarDB

[![CI](https://img.shields.io/badge/ci-passing-brightgreen)](https://github.com/anthropics/northstardb/actions)
[![License](https://img.shields.io/badge/license-MIT-blue)](./LICENSE)

A Zig database built for massive read concurrency and deterministic replay.
```

### Release Notes

```markdown
## Version X.Y.Z (YYYY-MM-DD)

### Added
- New feature description

### Changed
- Breaking change with migration guide

### Fixed
- Bug fix description

### Performance
- 2x improvement in...

 Contributors: @username1, @username2
```

## Enforcement

These guidelines are maintained by the documentation team. For questions:
- Open an issue with the `documentation` label
- Start a Discussion: https://github.com/anthropics/northstardb/discussions
- Join `#documentation` on Discord

---

**Last Updated**: 2025-12-28
