# Haxeon website

Use Node.js 24 (see `.nvmrc`) and stock Haxe. The CLI help generator uses the checkout's Haxe from
`scripts/bootstrap-tools.sh` when available, or `haxe` on PATH. Set `HAXE` to choose a different executable.

Run these commands from `site/`.

```sh
npm ci
npm run dev
npm run build
npm run check:commands
npm run check:embeds
npm run check:links
npm run check:template-web
npm run check:grammars
npm run check:examples
```

The Website workflow (`.github/workflows/site.yml`) runs these after `npm run build:gpu-modules`, `npm run build`,
`npm run build:showcase` and `npm run build:circuit-run`; run the same list before pushing a site change.

`npm run build:gpu-modules`, before `npm run build`, generates the shader module the GPU page
quotes from the Triangle example into the git-ignored `generated/`. It needs the native Haxeon
CLI from `scripts/build-native.sh`; without it the page build stops and names this step.

`npm run build:showcase`, after `npm run build`, builds the live WebGL2 UI Showcase on /ui/ from
source with CMake, Ninja, the pinned Emscripten toolchain and Python FontTools, into `dist/`. It
installs Emscripten on its first run and reuses the build directory under `out/site-showcase`
afterwards. CI and the deploy run it; without it /ui/ shows the Showcase's preview image. Use
`npm run preview` after both to exercise the live Showcase.

`npm run build:circuit-run` adds the playable WebGL2 Circuit Run example to /gpu/ after the static build.
It uses the same Emscripten SDK and requires the native Haxeon CLI from `scripts/build-native.sh`.
The Website workflow builds it. The static page shows the desktop capture and source links on its own.

Open the URL printed by Astro. The production build is static HTML in `dist/`. Use
`npm run preview` to serve it locally. Set `ASTRO_TELEMETRY_DISABLED=1` in environments with a
read-only home directory.

Starlight reads Markdown directly from `../docs/guides/`, `../docs/reference/`, `../docs/learn/` and
`../docs/coming-from/`. Open pages with a Markdown heading or use Starlight frontmatter for metadata. Links can stay
relative to the source files. The site rewrites links between published pages and links to guide examples in the
repository. The build appends the overview help to the CLI overview and inserts each command's help under its heading
on the corresponding group page. The help and group order come from `../src/tools/CliHelp.hx`.

The home, Language, UI, GPU, Build, Examples and About pages use `src/layouts/SplashPage.astro`, Starlight's `splash`
template with the product-page wrapper. Starlight owns page metadata, search and the theme switch. Its component
overrides provide the shared site header and footer, including page navigation and last-updated metadata where
available. Splash pages provide their own visible heading and full-width section layout; the sections more than one
page uses live in `src/components/sections/`.

`src/styles/tokens.json` defines the palette and typography. `src/styles/theme.css` maps them to Starlight's
custom properties and defines the site's own properties for details such as the display font and card radii. Keep
component styles in their Astro components and use the shared landing styles (`src/styles/landing.css`) for section,
grid and button primitives. Those rules have no specificity, so a component's own rule always overrides them.

`Command.astro`, `CodeCard.astro`, `Card.astro` and `PlatformTable.astro` live in `src/components/` for the Astro
pages; the docs are plain Markdown. Expressive Code renders the component and Markdown code examples
with the same grammar and theme. Use `sh`, `bash`, `shell`, or `console` for shell commands and
`powershell`, `ps1`, or `pwsh` for PowerShell commands. Use `text` for output. The command strip adds a
display prompt to each command line and a copy button for the fence contents. Shell script examples and
transcripts can use the Expressive Code `frame="code"` option. With Google Chrome installed, run
`npm run check:commands` after building to verify the Get started guide's command text, prompts, wrapping,
and clipboard contents.

After building the Showcase and Circuit Run, run `npm run check:embeds` to start every live embed in Chrome at desktop
and mobile widths and check that a failed load can be retried. `npm run check:template-web` builds the app template for
the web and clicks its counter. The browser checks use `CHROME_BIN` when it is set, and save what they saw under
`SCREENSHOT_DIR` when that is set.

After bootstrapping and building the native toolchain, run `npm run check:examples` to run every code sample a built page
marks with `example`, compare its output, check the generated geometry binding, and run the UI page's counter. The
counter runs the first-app guide project and exercises its button. On headless Linux the check uses Xvfb.
Run `npm run check:grammars` to check the shared TextMate grammars against
the lexer and an imported C fixture. The repository's `docs-guides` suite verifies the guide projects.

`public/ui/` holds the counter window and the light and dark Controls captures from the desktop UI Showcase.

The default build displays `main`. When building from a release checkout, set `HAXEON_SITE_VERSION` to its Git tag.
Set `HAXEON_SITE_MAIN_URL` to the published main docs URL to offer a link back to main from a release build.
