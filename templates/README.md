# Project templates

`haxeon create` copies one of these directories into a new project (docs/design/PROJECT_BUILDS.md), replacing each
`{{NAME}}` with the project's value:

| Placeholder | Value |
| --- | --- |
| `{{package}}` | the package name: the project directory's name |
| `{{name}}` | the app's display name |
| `{{id}}` | the app's reverse-domain identifier (`--org` and the package name) |
| `{{platforms}}` | the app's platforms as a TOML array |
| `{{haxeon}}` | the Haxeon installation's directory, for its packages until they come from the `haxeon` registry |

A top-level directory named after a platform (`linux/`, later `windows/`, `macos/`, `android/`, `web/`) is that platform's
runner project (docs/design/PROJECT_BUILDS.md), copied only for the platforms the app lists. A file whose name ends in
`.template` loses that suffix when it is copied, so a template can hold a file the repository
would otherwise treat as its own (a `haxeon.toml`). Each template is created, built and run by
`tests/integration/test-project-templates.hx`.
