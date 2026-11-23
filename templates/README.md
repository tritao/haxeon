# Project templates

`haxeon create` copies one of these directories into a new project (docs/design/PROJECT_BUILDS.md), replacing each
`{{NAME}}` with the project's value:

| Placeholder | Value |
| --- | --- |
| `{{package}}` | the package name: the project directory's name |
| `{{name}}` | the app's display name |
| `{{id}}` | the app's reverse-domain identifier (`--org` and the package name) |
| `{{platforms}}` | the app's platforms as a TOML array |
| `{{haxeon_version}}` | Haxeon's major and minor version (`0.3`): the SDK a runner finds, the Haxeon the project is compatible with, and the range of the packages from the `haxeon` registry, versioned with it |

A top-level directory named after a platform (`linux/`, `macos/`, `windows/`, `android/`, `web/`) is that platform's
runner project (docs/design/PROJECT_BUILDS.md), copied only for the platforms the app lists. A file whose name ends in
`.template` loses that suffix when it is copied, so a template can hold a file the repository
would otherwise treat as its own (a `haxeon.toml`). Each template is created, built and run by
`tests/integration/test-project-templates.hx`.

The guides start from the app template (docs/guides/01-first-app.md): their example projects under `docs/guides/examples/`
are its output with the guides' changes, so a change to the template's `haxeon.toml` or `src/Main.hx` goes there too
(`tests/integration/test-docs-guides.hx` checks the manifest).

The app template uses the UI counter on desktop and a managed entry point on Android and web.
The Android project packages the SDK host and generated assets. The web page loads the SDK Wasm host.
