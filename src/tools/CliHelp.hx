package tools;

private typedef CommandHelp = {
	/** The command as typed; a placeholder (`SCRIPT.hx`) for a form that is not a word. */
	final name:String;

	final summary:String;

	/** The command's own help: its usage line, then its options. */
	final details:Array<String>;
}

private typedef CommandGroup = {
	final title:String;
	final commands:Array<CommandHelp>;
}

/** The CLI's help: the global overview, grouped by task, and each command's own (`haxeon help build`, `haxeon build --help`). */
class CliHelp {
	static final BUILD_OPTIONS = [
		"  --project PATH               The manifest to build, or its directory (default: this directory's haxeon.toml or haxeon.json)",
		"  --target TARGET              host, android, wasm32 or OS-ARCH (default: the project's; see haxeon platforms)",
		"  --build-mode MODE            development (default) or release",
		"  --define NAME[=VALUE]        Add a conditional compilation define (repeatable)",
		"  --output PATH                Write the module to PATH",
		"  -v, --verbosity LEVEL        quiet, minimal (default), normal, detailed or diagnostic",
		"  --color WHEN                 Colour diagnostics: auto (default; honours NO_COLOR), always or never",
		"  --diagnostic-format FORMAT   full (default) or short, one line per diagnostic",
		"  --jobs COUNT                 Run up to COUNT independent actions at once (default 4)",
		"  --self-hosted                Compile with bootstrap/compiler.hl",
	];

	static final GROUPS:Array<CommandGroup> = [
		{
			title: "Project",
			commands: [
				{
					name: "create",
					summary: "Create a project from a template, or add what one lacks",
					details: [
						"Usage: haxeon create DIRECTORY [-t|--template app|console] [--platforms LIST] [--org PREFIX]",
						"",
						"  DIRECTORY                    A new directory, or . to add the template's missing files here",
						"  -t, --template NAME          app (default: a window, with an [app] section) or console (a console program)",
						"  --platforms LIST             An app's platforms, comma-separated (default: every platform the template has a runner for)",
						"  --org PREFIX                 The app identifier's prefix (default com.example)",
						"",
						"  Existing files are never overwritten."
					]
				},
				{
					name: "init",
					summary: "Create haxeon.toml and src/Main.hx in this directory (to be replaced by create)",
					details: [
						"Usage: haxeon init [--entry Main] [--target host|wasm32|android]",
						"",
						"  --entry NAME                 The entry module (default Main)",
						"  --target TARGET              host (default), wasm32 or android"
					]
				},
				{
					name: "migrate",
					summary: "Turn the project's haxeon.json into haxeon.toml",
					details: [
						"Usage: haxeon migrate [--dry-run] [--project PATH]",
						"",
						"Writes haxeon.toml with the same settings, checks that it reads back to them, and removes haxeon.json.",
						"",
						"  --dry-run                    Print the haxeon.toml instead of writing it",
						"  --project PATH               The haxeon.json, or its directory (default: this directory)"
					]
				},
				{
					name: "clean",
					summary: "Remove the project's build outputs",
					details: [
						"Usage: haxeon clean [--project PATH]",
						"",
						"Removes the project's outputDir (and the instrumented build's beside it) and its tests project's.",
						"Caches shared between projects stay."
					]
				},
				{
					name: "doctor",
					summary: "Check the installation, the C and C++ toolchain, and Android tools",
					details: ["Usage: haxeon doctor"]
				},
				{
					name: "platforms",
					summary: "Show the targets this CLI builds for",
					details: ["Usage: haxeon platforms"]
				},
				{
					name: "devices",
					summary: "List connected Android devices",
					details: ["Usage: haxeon devices"]
				}
			]
		},
		{
			title: "Build & run",
			commands: [
				{
					name: "build",
					summary: "Build the project in haxeon.toml (or haxeon.json)",
					details: [
						"Usage: haxeon build [options]",
						""
					].concat(BUILD_OPTIONS).concat([
						"  --plan                       Print the artifact and action plans instead of building",
						"  --explain                    With --plan, say why each artifact is there",
						"  --timings                    Print where the build's time went, and the compiler's reports",
						"  --compiler-only              Run only the Haxe compile",
						"  --gradle-inputs FILE         Android: build what Gradle packages and describe it in FILE"
					])
				},
				{
					name: "check",
					summary: "Type-check the project, writing nothing",
					details: [
						"Usage: haxeon check [options]",
						"",
						"Reports the diagnostics a build would, without generating or writing a module.",
						""
					].concat(BUILD_OPTIONS.filter(line -> line.indexOf("--output") < 0
						&& line.indexOf("--self-hosted") < 0))
						.concat(["  --timings                    Print where the check's time went, and the compiler's reports"])
				},
				{
					name: "run",
					summary: "Build, then launch the program (host or Android)",
					details: [
						"Usage: haxeon run [options] [-- PROGRAM ARGUMENTS]",
						"       haxeon run SCRIPT.hx [ARGUMENTS]",
						""
					].concat(BUILD_OPTIONS).concat([
						"  --quiet                      Print the build only if it fails",
						"  --device SERIAL              The Android device to run on",
						"  --watch                      Rebuild and relaunch on source edits",
						"  --watch --live               Patch the running host module instead of relaunching",
						"  --strict-live                With --live, report an edit that cannot patch instead of reloading",
						"  --profile[=SOURCES]          Record a profile: instrument (default), sampling, alloc",
						"  --profile-output PATH        Where the capture goes (implies --profile)",
						"  --profile-start=launch|manual, --profile-duration=SEC, --profile-max-size=MIB,",
						"  --profile-window=START:END, --profile-min-call=US   (docs/reference/PROFILING.md)"
					])
				},
				{
					name: "SCRIPT.hx",
					summary: "Build and run one Haxe file, with no project",
					details: ["Usage: haxeon SCRIPT.hx [ARGUMENTS]   (or haxeon run SCRIPT.hx [ARGUMENTS])"]
				},
				{
					name: "FILE.hxml",
					summary: "Build a Haxe command line or .hxml file",
					details: [
						"Usage: haxeon BUILD.hxml   or   haxeon -cp src -main Main --hl out.hl",
						"",
						"Reads Haxe's arguments as Haxe does (.hxml files, --next, --each, --cwd) and builds each compilation:",
						"  -cp, -main, -D, --hl FILE.hl, --debug, --dce std|full, --no-inline, --no-output, --cmd, -lib NAME:VERSION,",
						"  -v, --times, dot paths. No target (or --no-output) checks the program, as Haxe only types it then.",
						"Anything else (--js, --interp, --macro, ...) is one error listing each. See 'Haxe command lines' in CLI.md."
					]
				},
				{
					name: "workspace",
					summary: "Build or test many projects as one build graph",
					details: [
						"Usage: haxeon workspace plan|build|test [options]",
						"",
						"  --workspace PATH             The workspace file (default materia.workspace.json)",
						"  --skip-tag TAG, --only NAME  Choose the projects",
						"  --jobs N, --compilers N      Job limit and simultaneous compiles",
						"  --no-test-cache              Run every test, cached or not",
						"  --actions                    With plan, list every action"
					]
				}
			]
		},
		{
			title: "Test & quality",
			commands: [
				{
					name: "test",
					summary: "Build the project's tests (the project in tests/) and run them",
					details: [
						"Usage: haxeon test [options] [-- TEST ARGUMENTS]",
						"",
						"Builds and runs the project in tests/ beside the project (or the project itself in a directory named tests),",
						"and exits with 0 when the tests pass and 1 when they fail.",
						""
					].concat(BUILD_OPTIONS.filter(line -> line.indexOf("--target") < 0)).concat([
						"  --quiet                      Print the build only if it fails",
						"  --watch                      Build and run the tests again on source edits"
					])
				},
				{
					name: "fmt",
					summary: "Format Haxe source files",
					details: [
						"Usage: haxeon fmt [--check] PATH... | --stdin",
						"",
						"  --check                      Report files that would change instead of rewriting them",
						"  --stdin                      Format standard input to standard output",
						"The style comes from the [format] section of haxeon.toml or haxeon.json (default: tabs, 120 columns)."
					]
				},
				{
					name: "lint",
					summary: "Report (or fix) unused imports and imports out of order",
					details: [
						"Usage: haxeon lint [--fix] [--only RULE] [--manifest FILE]... FILE...",
						"",
						"  --fix                        Remove unused imports and sort them",
						"  --only RULE                  unused-imports, import-order; opt-in: unbound-local, module-namespace,",
						"                               throw-non-exception",
						"  --manifest FILE              A haxeon.toml or haxeon.json whose source roots resolve imports"
					]
				}
			]
		},
		{
			title: "Packages",
			commands: [
				{
					name: "add",
					summary: "Add a package dependency",
					details: [
						"Usage: haxeon add NAME [--version RANGE] [--registry NAME] [--project PATH]",
						"       haxeon add --git URL --rev REF [NAME] [--project PATH]",
						"  NAME alone adds the latest release from the haxeon registry, written as NAME = \"^VERSION\""
					]
				},
				{
					name: "install",
					summary: "Resolve dependencies and write haxeon.lock",
					details: ["Usage: haxeon install [--locked] [--project PATH]"]
				},
				{
					name: "update",
					summary: "Resolve refs again and rewrite haxeon.lock",
					details: ["Usage: haxeon update [--project PATH]"]
				},
				{
					name: "tree",
					summary: "Show the resolved package graph",
					details: ["Usage: haxeon tree [--project PATH]"]
				},
				{
					name: "why",
					summary: "Show how a package is reached",
					details: ["Usage: haxeon why PACKAGE [--project PATH]"]
				},
				{
					name: "publish",
					summary: "Publish an immutable local release",
					details: ["Usage: haxeon publish --registry NAME --version VERSION [--project PATH]"]
				},
				{
					name: "package",
					summary: "Validate the resolved package graph",
					details: ["Usage: haxeon package check [--project PATH]"]
				}
			]
		},
		{
			title: "Tools",
			commands: [
				{
					name: "lsp",
					summary: "The language server, over standard input and output",
					details: ["Usage: haxeon lsp"]
				},
				{
					name: "ffi",
					summary: "Import C or C++ headers as HXI, or audit their ABI across targets",
					details: [
						"Usage: haxeon ffi import ...   (docs/reference/C_HEADER_FFI.md)",
						"       haxeon ffi audit ... [--capture DIR] [--report PATH]"
					]
				},
				{
					name: "heap",
					summary: "Inspect a HashLink heap snapshot",
					details: ["Usage: haxeon heap inspect BYTECODE DUMP"]
				},
				{
					name: "identity-path",
					summary: "Why the code identity of one module depends on another",
					details: ["Usage: haxeon identity-path [--project PATH] FROM TO"]
				},
				{
					name: "dev",
					summary: "Checkout tasks: tool builds, the test driver (see 'haxeon dev help')",
					details: ["Usage: haxeon dev COMMAND ...   (haxeon dev help lists them)"]
				},
				{
					name: "version",
					summary: "Print the versions of haxeon, its compiler and HashLink",
					details: ["Usage: haxeon version   (or haxeon --version)"]
				},
				{
					name: "help",
					summary: "Print this help, or a command's",
					details: ["Usage: haxeon help [COMMAND]   (or haxeon COMMAND --help)"]
				}
			]
		}
	];

	/** Every command name, for suggestions. */
	public static function commandNames():Array<String>
		return [
			for (group in GROUPS)
				for (command in group.commands)
				if (command.name.indexOf(".") < 0) command.name
		];

	/** The overview: each group's commands with a line each. */
	public static function overview():String {
		var lines = ["Usage: haxeon <command> [options]", ""];
		for (group in GROUPS) {
			lines.push(group.title + ":");
			for (command in group.commands)
				lines.push("  " + StringTools.rpad(command.name, " ", 16) + command.summary);
			lines.push("");
		}
		lines.push("Run 'haxeon help <command>' or 'haxeon <command> --help' for a command's options.");
		lines.push("Docs: docs/reference/CLI.md");
		return lines.join("\n");
	}

	/** A command's own help, or null when there is no such command. */
	public static function command(name:String):Null<String> {
		for (group in GROUPS)
			for (command in group.commands)
				if (command.name == name)
					return command.summary + "\n\n" + command.details.join("\n");
		return null;
	}

	/** The command closest to `typed` by edit distance, when it is close enough to be a typo. */
	public static function suggestion(typed:String):Null<String> {
		var best:Null<String> = null, bestDistance = 0;
		for (name in commandNames()) {
			var distance = editDistance(typed, name);
			if (best == null || distance < bestDistance) {
				best = name;
				bestDistance = distance;
			}
		}
		return best != null && bestDistance <= (best.length <= 3 ? 1 : (best.length <= 8 ? 2 : 3)) ? best : null;
	}

	static function editDistance(left:String, right:String):Int {
		var previous = [for (index in 0...right.length + 1) index];
		for (i in 0...left.length) {
			var current = [i + 1];
			for (j in 0...right.length) {
				var substitution = previous[j] + (left.charCodeAt(i) == right.charCodeAt(j) ? 0 : 1);
				current.push(Std.int(Math.min(substitution, Math.min(previous[j + 1] + 1, current[j] + 1))));
			}
			previous = current;
		}
		return previous[right.length];
	}
}
