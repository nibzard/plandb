.PHONY: all clean

WASM = example_runner.wasm

all: $(WASM)

$(WASM): example_runner.zig
	zig build-lib \
		-target wasm32-freestanding \
		-ofmt=wasm \
		-O ReleaseSmall \
		-name example_runner \
		example_runner.zig
	if [ -f libexample_runner.a ]; then \
		ar x libexample_runner.a example_runner.o 2>/dev/null || \
		wasm-objdump -h libexample_runner.a 2>/dev/null || \
		mv libexample_runner.a $(WASM) 2>/dev/null || \
		cp libexample_runner.a $(WASM); \
	fi

clean:
	rm -f $(WASM) libexample_runner.a
	rm -rf .zig-cache zig-out
