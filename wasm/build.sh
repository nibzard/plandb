#!/bin/bash
# Build script for WebAssembly example runner

set -e

cd "$(dirname "$0")"

echo "Building WebAssembly module..."

# Build the WASM library
zig build-lib \
    -target wasm32-freestanding \
    -ofmt=wasm \
    -O ReleaseSmall \
    example_runner.zig

# Extract WASM from ar archive (zig wraps it)
python3 -c "
import sys
with open('libexample_runner.a', 'rb') as f:
    data = f.read()
# Find WASM magic (0x00 0x61 0x73 0x6d)
wasm_start = data.find(b'\x00asm')
if wasm_start > 0:
    wasm_data = data[wasm_start:]
    # Find end (next ar header or EOF)
    end = wasm_data.find(b'!<arch>')
    if end > 0:
        wasm_data = wasm_data[:end]
    with open('example_runner.wasm', 'wb') as out:
        out.write(wasm_data)
    print(f'Extracted {len(wasm_data)} bytes')
else:
    print('No WASM found', file=sys.stderr)
    sys.exit(1)
"

# Verify the WASM file
if command -v wasm-validate &> /dev/null; then
    wasm-validate example_runner.wasm
    echo "WASM validation passed"
fi

echo "Built: example_runner.wasm"
