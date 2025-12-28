/**
 * NorthstarDB WebAssembly Code Runner
 *
 * Provides a JavaScript API for executing Zig code examples in the browser.
 * Handles WASM instantiation, memory management, and result formatting.
 */

export class NorthstarWasmRunner {
    /**
     * Create a new WASM runner instance
     * @param {Response|ArrayBuffer} wasmSource - WASM binary or fetch response
     */
    constructor(wasmSource) {
        this.wasmSource = wasmSource;
        this.instance = null;
        this.memory = null;
        this.initialized = false;
    }

    /**
     * Initialize the WASM module
     */
    async init() {
        if (this.initialized) return;

        const wasmBytes = this.wasmSource instanceof ArrayBuffer
            ? this.wasmSource
            : await this.wasmSource.arrayBuffer();

        const module = await WebAssembly.instantiate(wasmBytes);
        this.instance = module.instance;
        this.memory = new Uint8Array(this.instance.exports.memory.buffer);

        // Initialize the runner
        this.instance.exports.init();
        this.initialized = true;
    }

    /**
     * Execute a put operation
     * @param {string} key - Key to set
     * @param {string} value - Value to store
     * @returns {object} Result with success flag and output
     */
    put(key, value) {
        this.ensureInitialized();

        const keyBytes = new TextEncoder().encode(key);
        const valueBytes = new TextEncoder().encode(value);

        // Build input: key_len(4) + value_len(4) + key + value
        const inputLen = 8 + keyBytes.length + valueBytes.length;
        const inputOffset = this.alloc(inputLen);

        // Write key length
        this.view.setUint32(inputOffset, keyBytes.length, true);
        // Write value length
        this.view.setUint32(inputOffset + 4, valueBytes.length, true);
        // Write key
        this.memory.set(keyBytes, inputOffset + 8);
        // Write value
        this.memory.set(valueBytes, inputOffset + 8 + keyBytes.length);

        // Execute
        const errorCode = this.instance.exports.exec_put(inputOffset, inputLen);

        return this.getResult(errorCode);
    }

    /**
     * Execute a get operation
     * @param {string} key - Key to retrieve
     * @returns {object} Result with success flag and output
     */
    get(key) {
        this.ensureInitialized();

        const keyBytes = new TextEncoder().encode(key);

        // Build input: key_len(4) + key
        const inputLen = 4 + keyBytes.length;
        const inputOffset = this.alloc(inputLen);

        // Write key length
        this.view.setUint32(inputOffset, keyBytes.length, true);
        // Write key
        this.memory.set(keyBytes, inputOffset + 4);

        // Execute
        const errorCode = this.instance.exports.exec_get(inputOffset, inputLen);

        return this.getResult(errorCode);
    }

    /**
     * Run a code snippet (example interface)
     * @param {string} code - Zig code snippet
     * @returns {object} Execution result
     */
    async runCode(code) {
        // For now, this is a placeholder that parses simple operations
        // Full implementation would compile Zig to WASM on-the-fly
        const trimmed = code.trim();

        if (trimmed.startsWith("put:") || trimmed.startsWith("PUT:")) {
            const parts = trimmed.substring(4).split("=");
            if (parts.length === 2) {
                return this.put(parts[0].trim(), parts[1].trim());
            }
        }

        if (trimmed.startsWith("get:") || trimmed.startsWith("GET:")) {
            return this.get(trimmed.substring(4).trim());
        }

        return {
            success: false,
            error: "Unsupported operation. Use 'put:key=value' or 'get:key'",
            output: ""
        };
    }

    /**
     * Get the result from the last operation
     * @param {number} errorCode - Error code from WASM export
     * @returns {object} Result object
     */
    getResult(errorCode) {
        if (errorCode !== 0) {
            const error = this.getError();
            return {
                success: false,
                error: error,
                output: ""
            };
        }

        const offset = this.instance.exports.get_result_offset();
        const len = this.instance.exports.get_result_len();
        const output = new TextDecoder().decode(
            this.memory.subarray(offset, offset + len)
        );

        return {
            success: true,
            error: null,
            output: output
        };
    }

    /**
     * Get the last error message
     * @returns {string} Error message
     */
    getError() {
        const offset = this.instance.exports.get_error_offset();
        const len = this.instance.exports.get_error_len();
        return new TextDecoder().decode(
            this.memory.subarray(offset, offset + len)
        );
    }

    /**
     * Allocate space in WASM memory
     * @param {number} size - Bytes to allocate
     * @returns {number} Offset in WASM memory
     */
    alloc(size) {
        // Simple allocator starting at offset 0
        // Real implementation would track allocations
        return 0;
    }

    /**
     * Get a DataView for writing to WASM memory
     */
    get view() {
        return new DataView(this.instance.exports.memory.buffer);
    }

    /**
     * Ensure the runner is initialized
     */
    ensureInitialized() {
        if (!this.initialized) {
            throw new Error("WasmRunner not initialized. Call init() first.");
        }
    }

    /**
     * Clear the result buffer
     */
    clear() {
        this.ensureInitialized();
        this.instance.exports.clear_result();
    }

    /**
     * Reset the runner state
     */
    reset() {
        this.clear();
    }
}

/**
 * Factory function to create and initialize a runner
 * @param {string} wasmUrl - URL to WASM file
 * @returns {Promise<NorthstarWasmRunner>} Initialized runner
 */
export async function createRunner(wasmUrl) {
    const response = await fetch(wasmUrl);
    const runner = new NorthstarWasmRunner(response);
    await runner.init();
    return runner;
}
