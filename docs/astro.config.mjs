// @ts-check
import { defineConfig } from 'astro/config';
import starlight from '@astrojs/starlight';

// https://astro.build/config
export default defineConfig({
	image: {
		service: {
			entrypoint: 'astro/assets/services/noop',
		},
	},
	integrations: [
		starlight({
			title: 'NorthstarDB',
			locales: {
				root: {
					label: 'English',
					lang: 'en',
				},
			},
			description: 'A Living Database built from scratch in Zig for massive read concurrency and deterministic replay.',
			social: [
				{ icon: 'github', label: 'GitHub', href: 'https://github.com/nikopol/northstardb' },
			],
			sidebar: [
				{
					label: 'Getting Started',
					items: [
						{ label: 'Introduction', slug: 'guides/introduction' },
						{ label: 'Quick Start', slug: 'guides/quick-start' },
						{ label: 'Installation', slug: 'guides/installation' },
					],
				},
				{ label: 'FAQ', slug: 'faq' },
				{ label: 'Contributing', slug: 'contributing' },
				{
					label: 'Core Concepts',
					items: [
						{ label: 'Architecture', slug: 'concepts/architecture' },
						{ label: 'Storage Engine', slug: 'concepts/storage' },
						{ label: 'B+tree Index', slug: 'concepts/btree' },
						{ label: 'MVCC', slug: 'concepts/mvcc' },
					],
				},
				{
					label: 'API Reference',
					autogenerate: { directory: 'reference' },
				},
				{
					label: 'Auto-Generated API Docs',
					items: [
						{
							label: 'Zig API Documentation',
							href: '/api/index.html',
							badge: {
								text: 'Generated',
								variant: 'note'
							}
						}
					]
				},
				{
					label: 'Specifications',
					items: [
						{ label: 'File Format v0', slug: 'specs/file-format-v0' },
						{ label: 'Semantics v0', slug: 'specs/semantics-v0' },
						{ label: 'Benchmarks v0', slug: 'specs/benchmarks-v0' },
						{ label: 'Hardening v0', slug: 'specs/hardening-v0' },
					],
				},
				{
					label: 'AI Intelligence',
					items: [
						{ label: 'Overview', slug: 'ai/overview' },
						{ label: 'Living Database Plan', slug: 'ai/living-db-plan' },
						{ label: 'Plugin System', slug: 'ai/plugins' },
						{ label: 'Structured Memory', slug: 'ai/structured-memory' },
					],
				},
				{
					label: 'Troubleshooting',
					autogenerate: { directory: 'troubleshooting' },
				},
			],
			head: [
				{
					tag: 'link',
					attrs: {
						rel: 'icon',
						type: 'image/svg+xml',
						href: '/favicon.svg',
					},
				},
			],
		}),
	],
});
