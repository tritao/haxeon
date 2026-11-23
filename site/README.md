# Haxeon website

Use Node.js 24 (see `.nvmrc`) and stock Haxe. The CLI help generator uses the checkout's Haxe from
`scripts/bootstrap-tools.sh` when available, or `haxe` on PATH. Set `HAXE` to choose a different executable.

Run these commands from `site/`.

```sh
npm ci
npm run dev
npm run build
npm run check:links
```

Open the URL printed by Astro. The production build is static HTML in `dist/`. Use
`npm run preview` to serve it locally. Set `ASTRO_TELEMETRY_DISABLED=1` in environments with a
read-only home directory.

Starlight reads Markdown directly from `../docs/guides/`, `../docs/reference/`, `../docs/learn/` and
`../docs/coming-from/`. Open pages with a Markdown heading or use Starlight frontmatter for metadata. Links can stay
relative to the source files. The site rewrites links between published pages and links to guide examples in the
repository. The CLI page appends command help generated from `../src/tools/CliHelp.hx` on each build.

After bootstrapping and building the native toolchain, run `npm run check:examples` to verify the homepage's program
outputs and generated geometry binding. Run `npm run check:grammars` to check the shared TextMate grammars against
the lexer and an imported C fixture. The repository's `docs-guides` suite verifies the guide projects.

The default build displays `main`. When building from a release checkout, set `HAXEON_SITE_VERSION` to its Git tag.
Set `HAXEON_SITE_MAIN_URL` to the published main docs URL to offer a link back to main from a release build.
