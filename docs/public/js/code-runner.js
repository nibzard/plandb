/**
 * NorthstarDB Interactive Code Runner
 *
 * Client-side JavaScript for embedding WebAssembly-based code examples
 * in Starlight documentation pages.
 */

class CodeRunner {
	constructor(container) {
		this.container = container;
		this.runner = null;
		this.currentExample = 0;
		this.examples = [];

		// Cache DOM elements
		this.elements = {
			loading: container.querySelector('.code-runner-loading'),
			error: container.querySelector('.code-runner-error'),
			errorDetails: container.querySelector('.code-runner-error-details'),
			content: container.querySelector('.code-runner-content'),
			selector: container.querySelector('.code-runner-selector'),
			select: container.querySelector('.code-runner-select'),
			description: container.querySelector('.code-runner-description'),
			editor: container.querySelector('.code-runner-textarea'),
			output: container.querySelector('.code-runner-output-content'),
			statusDot: container.querySelector('.code-runner-status-dot'),
			statusText: container.querySelector('.code-runner-status-text'),
			executionTime: container.querySelector('.code-runner-time'),
			btnRun: container.querySelector('.code-runner-btn-run'),
			btnCopy: container.querySelector('.code-runner-btn-copy'),
			btnClear: container.querySelector('.code-runner-btn-clear'),
			btnRetry: container.querySelector('.code-runner-btn-retry'),
		};

		this.init();
	}

	async init() {
		// Parse examples from inline script tag or data attribute
		try {
			const scriptTag = this.container.querySelector('script[type="application/json"]');
			if (scriptTag) {
				this.examples = JSON.parse(scriptTag.textContent || '[]');
			} else {
				this.examples = JSON.parse(this.container.dataset.examples || '[]');
			}
			this.currentExample = parseInt(this.container.dataset.defaultIndex || '0');

			// Populate example selector
			this.examples.forEach((ex, i) => {
				const option = document.createElement('option');
				option.value = i;
				option.textContent = ex.name;
				if (i === this.currentExample) option.selected = true;
				this.elements.select.appendChild(option);
			});

			// Load WASM module
			const { createRunner } = await import('/wasm/runner.js');
			this.runner = await createRunner('/wasm/example_runner.wasm');

			// Show content
			this.elements.loading.style.display = 'none';
			this.elements.content.style.display = 'flex';
			this.loadExample(this.currentExample);
			this.setStatus('ready');
			this.bindEvents();
		} catch (error) {
			this.elements.loading.style.display = 'none';
			this.elements.error.style.display = 'flex';
			this.elements.errorDetails.textContent = error.message || String(error);
		}
	}

	loadExample(index) {
		this.currentExample = index;
		const example = this.examples[index];
		this.elements.editor.value = example.code;
		this.elements.description.textContent = example.description || example.name;
	}

	async runCode() {
		const code = this.elements.editor.value;
		if (!code.trim()) return;

		this.setStatus('running');
		this.elements.output.innerHTML = '';
		const startTime = performance.now();

		const lines = code.split('\n').filter(l => l.trim() && !l.trim().startsWith('//'));

		for (const line of lines) {
			try {
				const result = await this.runner.runCode(line.trim());
				if (result.success) {
					this.appendOutput(result.output, 'success');
				} else if (result.error) {
					this.appendOutput(result.error, 'error');
				}
			} catch (error) {
				this.appendOutput(`Error: ${error.message}`, 'error');
			}
		}

		const totalTime = (performance.now() - startTime).toFixed(2);
		this.elements.executionTime.textContent = `${totalTime}ms`;
		this.setStatus('ready');
	}

	appendOutput(text, type = 'info') {
		const line = document.createElement('div');
		line.className = `code-runner-output-line code-runner-output-${type}`;
		line.textContent = text;
		this.elements.output.appendChild(line);
		this.elements.output.scrollTop = this.elements.output.scrollHeight;
	}

	setStatus(status) {
		this.elements.statusDot.className = `code-runner-status-dot ${status}`;
		this.elements.statusText.textContent = status.charAt(0).toUpperCase() + status.slice(1);
		this.elements.btnRun.disabled = status === 'running';
	}

	copyCode() {
		navigator.clipboard.writeText(this.elements.editor.value);

		const originalHTML = this.elements.btnCopy.innerHTML;
		this.elements.btnCopy.innerHTML = 'Copied!';
		setTimeout(() => {
			this.elements.btnCopy.innerHTML = originalHTML;
		}, 1500);
	}

	clearOutput() {
		this.elements.output.innerHTML = '';
		this.elements.executionTime.textContent = '';
	}

	bindEvents() {
		this.elements.select.addEventListener('change', (e) => {
			this.loadExample(parseInt(e.target.value));
		});

		this.elements.btnRun.addEventListener('click', () => this.runCode());
		this.elements.btnCopy.addEventListener('click', () => this.copyCode());
		this.elements.btnClear.addEventListener('click', () => this.clearOutput());
		this.elements.btnRetry.addEventListener('click', () => {
			this.elements.error.style.display = 'none';
			this.elements.loading.style.display = 'flex';
			this.init();
		});

		this.elements.editor.addEventListener('keydown', (e) => {
			if (e.key === 'Enter' && (e.ctrlKey || e.metaKey)) {
				e.preventDefault();
				this.runCode();
			}
			if (e.key === 'Tab') {
				e.preventDefault();
				const start = this.elements.editor.selectionStart;
				const end = this.elements.editor.selectionEnd;
				this.elements.editor.value = this.elements.editor.value.substring(0, start) + '    ' + this.elements.editor.value.substring(end);
				this.elements.editor.selectionStart = this.elements.editor.selectionEnd = start + 4;
			}
		});
	}
}

// Initialize all code runners on the page
function initCodeRunners() {
	document.querySelectorAll('.code-runner').forEach((container) => {
		// Skip if already initialized
		if (container.dataset.initialized) return;
		container.dataset.initialized = 'true';

		new CodeRunner(container);
	});
}

// Initialize on DOM ready and after page navigations
if (document.readyState === 'loading') {
	document.addEventListener('DOMContentLoaded', initCodeRunners);
} else {
	initCodeRunners();
}

// Support for Astro's View Transitions
document.addEventListener('astro:after-swap', initCodeRunners);
