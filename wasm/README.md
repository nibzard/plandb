# NorthstarDB WebAssembly Code Runner

A browser-based code runner for executing Zig code examples via WebAssembly.

## Building

Build the WebAssembly module using the provided build script:

```bash
cd wasm
./build.sh
```

This produces `example_runner.wasm`.

### Manual Build

If the script doesn't work, build manually:

```bash
# Build with zig (produces libexample_runner.a)
zig build-lib -target wasm32-freestanding -ofmt=wasm -O ReleaseSmall example_runner.zig

# Extract WASM from ar archive
python3 << 'EOF'
with open('libexample_runner.a', 'rb') as f:
    data = f.read()
wasm_start = data.find(b'\x00asm')
if wasm_start > 0:
    wasm_data = data[wasm_start:]
    end = wasm_data.find(b'!<arch>')
    if end > 0:
        wasm_data = wasm_data[:end]
    with open('example_runner.wasm', 'wb') as out:
        out.write(wasm_data)
EOF
```

## Running Locally

Serve the files with any HTTP server:

```bash
# Python 3
python -m http.server 8080

# Node.js
npx serve

# Then open
open http://localhost:8080/ui.html
```

## API

### JavaScript API

```javascript
import { createRunner } from './runner.js';

const runner = await createRunner('./example_runner.wasm');

// Execute operations
await runner.put('user:name', 'Alice');
const result = await runner.get('user:name');
console.log(result.output); // "GET: user:name -> [simulated value]"
```

### WASM Exports

- `memory` - Linear memory buffer
- `init() -> u32` - Initialize the runner
- `exec_put(offset, len) -> u32` - Execute put operation
- `exec_get(offset, len) -> u32` - Execute get operation
- `get_result_offset() -> u32` - Get result buffer offset
- `get_result_len() -> u32` - Get result buffer length
- `get_error_offset() -> u32` - Get error buffer offset
- `get_error_len() -> u32` - Get error buffer length
- `clear_result() -> void` - Clear result buffer

## Integration with Documentation

To integrate into Astro/Starlight documentation:

1. Copy `example_runner.wasm` and `runner.js` to `public/wasm/`
2. Add the runner component to your MDX components:

```astro
---
import CodeRunner from '../components/CodeRunner.astro';
---

<CodeRunner example="quick-start" />
```

## Examples

The runner includes pre-built examples:
- **Quick Start** - Basic key-value operations
- **Task Queue** - Simple task management
- **Counters** - Numeric counters
- **Session Data** - User session storage

## Architecture

```
┌─────────────────────────────────────────────────────┐
│                     ui.html                         │
│  ┌─────────────┐  ┌─────────────┐  ┌───────────┐  │
│  │ Code Editor │  │   Output    │  │ Examples  │  │
│  └──────┬──────┘  └─────────────┘  └───────────┘  │
└─────────┼──────────────────────────────────────────┘
          │
          ▼
┌─────────────────────────────────────────────────────┐
│                    runner.js                        │
│  ┌──────────────────────────────────────────────┐  │
│  │  NorthstarWasmRunner                         │  │
│  │  - init()                                    │  │
│  │  - put(key, value)                           │  │
│  │  - get(key)                                  │  │
│  │  - runCode(code)                             │  │
│  └──────────────────────────────────────────────┘  │
└─────────┼──────────────────────────────────────────┘
          │
          ▼
┌─────────────────────────────────────────────────────┐
│              example_runner.wasm                     │
│  ┌──────────────────────────────────────────────┐  │
│  │  Zig exports:                                │  │
│  │  - exec_put / exec_get                       │  │
│  │  - get_result_offset/len                     │  │
│  │  - memory buffer                             │  │
│  └──────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────┘
```

## Future Enhancements

- [ ] Real database operations (currently simulated)
- [ ] Support for more operations (scan, delete, etc.)
- [ ] Multiple database instances
- [ ] Persistence via IndexedDB
- [ ] Performance metrics and profiling
- [ ] Custom Zig code compilation to WASM
