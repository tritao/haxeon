# Haxeon website

Use Node.js 24 (see `.nvmrc`) and stock Haxe. The CLI help generator uses the checkout's Haxe from
`scripts/bootstrap-tools.sh` when available, or `haxe` on PATH. Set `HAXE` to choose a different executable.

Run these commands from `site/`.

```sh
npm ci
npm run dev
npm run build
npm run check:commands
npm run check:links
npm run check:examples
```

`npm run build:showcase`, after `npm run build`, builds the live WebGL2 UI Showcase on /ui/ from
source with CMake, Ninja, the pinned Emscripten toolchain and Python FontTools, into `dist/`. It
installs Emscripten on its first run and reuses the build directory under `out/site-showcase`
afterwards. CI and the deploy run it; without it /ui/ shows the Showcase's preview image. Use
`npm run preview` after both to exercise the live Showcase.

Open the URL printed by Astro. The production build is static HTML in `dist/`. Use
`npm run preview` to serve it locally. Set `ASTRO_TELEMETRY_DISABLED=1` in environments with a
read-only home directory.

Starlight reads Markdown directly from `../docs/guides/`, `../docs/reference/`, `../docs/learn/` and
`../docs/coming-from/`. Open pages with a Markdown heading or use Starlight frontmatter for metadata. Links can stay
relative to the source files. The site rewrites links between published pages and links to guide examples in the
repository. The CLI page appends command help generated from `../src/tools/CliHelp.hx` on each build.

The home, Language, UI, Build, Examples and About pages use `StarlightPage` with the `splash` template. Starlight owns
page metadata, search and the theme switch. Its component overrides provide the shared site header and footer,
including page navigation and last-updated metadata where available. Splash pages provide their own visible heading
and full-width section layout.

`src/styles/tokens.json` defines the palette and typography. `src/styles/theme.css` maps them to Starlight's
custom properties and defines the Haxeon properties for details such as the display font and card radii. Keep
component styles in their Astro components and use the shared landing styles for section and button primitives.

`Command.astro`, `CodeCard.astro`, `Card.astro` and `PlatformTable.astro` live in `src/components/` and can also
be imported in Astro or MDX docs pages. Expressive Code renders the component and Markdown code examples
with the same grammar and theme. Use `sh`, `bash`, `shell`, or `console` for shell commands and
`powershell`, `ps1`, or `pwsh` for PowerShell commands. Use `text` for output. The command strip adds a
display prompt to each command line and a copy button for the fence contents. Shell script examples and
transcripts can use the Expressive Code `frame="code"` option. With Google Chrome installed, run
`npm run check:commands` after building to verify the Get started guide's command text, prompts, wrapping,
and clipboard contents.

After bootstrapping and building the native toolchain, run `npm run check:examples` to verify the homepage program
outputs, the generated geometry binding, and the UI page's rendered counter. The counter runs the first-app guide project
and exercises its button. On headless Linux the check uses Xvfb.
Run `npm run check:grammars` to check the shared TextMate grammars against
the lexer and an imported C fixture. The repository's `docs-guides` suite verifies the guide projects.

`public/ui/` holds the counter window and the light and dark Controls captures from the desktop UI Showcase.

The default build displays `main`. When building from a release checkout, set `HAXEON_SITE_VERSION` to its Git tag.
Set `HAXEON_SITE_MAIN_URL` to the published main docs URL to offer a link back to main from a release build.
