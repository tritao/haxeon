package tools;
import build.shader.ShaderBuild;

import build.AotCompiler;
import build.BuildOutput;
import build.BuildScope;
import build.BuildSession;
import build.HashLinkPath;
import build.HaxeonProjectBuild;
import build.HaxeonSdk;
import build.NativeTargetSupport;
import build.Target;
import build.WorkspaceBuild;
import build.WorkspaceManifest;
import build.execution.ContentDigest;
import build.execution.DigestStore;
import build.execution.Executor;
import build.execution.JobServer;
import build.execution.OutputCapture;
import build.execution.ProcessRunner;
import build.native.ConsoleProgram;
import build.native.NativeCMakeProvider;
import build.native.ToolchainCheck;
import compiler.core.InternalError;
import compiler.core.TextDigest;
import compiler.core.UsageError;
import compiler.formatter.Formatter;
import compiler.formatter.ProjectFormat;
import compiler.tools.DiagnosticPrinter.DiagnosticFormat;
import compiler.tools.ReportStyle;
import compiler.tools.Verbosity;
import haxe.Json;
import haxe.io.Bytes;
import haxe.io.Path;
import haxeon.io.FileTree;
import project.PackageLockfile;
import project.PackageManifest;
import project.PackageManifest.AppManifest;
import project.PackageResolver;
import project.PackageSourceCodec;
import project.PackageSourceTools;
import project.ProjectDiscovery;
import project.RegistryIndex;
import project.RegistryPublisher;
import project.ResolvedPackage;
import project.ResolvedProject;
import project.SourceCache;
import sys.FileSystem;
import sys.io.File;
import tools.HaxeArguments.HaxeCompilation;
import tools.WatchRun.WatchChange;
import tools.WatchRun.WatchProfiling;

private typedef BuildOptions = {
	/** `--project`: a manifest, or a directory holding one (`.`, this directory's, by default). */
	final projectPath:String;
	final target:Null<String>;
	final buildMode:String;
	final buildModeExplicit:Bool;
	final output:Null<String>;
	final device:Null<String>;
	final defines:Array<String>;
	final runtimeArguments:Array<String>;
	final debugPort:Null<Int>;
	final launchPlan:Null<String>;
	final plan:Bool;
	final explain:Bool;
	final timings:Bool;

	/** `-v`/`--verbosity LEVEL`: what the build prints, `minimal` (a line before and after it) by default. */
	final verbosity:Verbosity;

	/**
	 * How the compiler reports: this verbosity, and diagnostics in the full format (`--diagnostic-format=full|short`), coloured on
	 * a terminal (`--color=auto|always|never`; auto honours NO_COLOR), with paths relative to where the command was run.
	 */
	final style:ReportStyle;

	/** `--quiet`: keep the build's progress, and print it (to standard error) only if the build fails. */
	final quiet:Bool;

	final compilerOnly:Bool;

	final gradleInputs:Null<String>;

	/** `--standard-library` (`haxeon doc`): describe the standard library, not a project. */
	final standardLibrary:Bool;

	/**
	 * `--watch` (`haxeon run`): rebuild on each edit and patch the running app in the live host when its entry class declares
	 * the host's entry points (`LiveHostBuild.missingEntryPoints`), else relaunch it.
	 */
	final watch:Bool;

	/** `--restart`, with `--watch`: relaunch the app on each edit even when the live host could patch it. */
	final restart:Bool;

	/**
	 * `--patchable`, with `build --compiler-only`: the compiler keeps the module's history, so each later build publishes a patch
	 * of it (`.hlp`, `.live.*`) for a host that applies patches itself, a phone's say.
	 */
	final patchable:Bool;

	/** `--strict-live`: report an edit that cannot patch instead of reloading the module, so unexpected reloads show. */
	final strictLive:Bool;

	final jobs:Int;
	final selfHosted:Bool;
	final profile:Bool;
	final profileSources:Array<String>;
	final profileOutput:Null<String>;
	final profileControls:ProfileCapture.ProfileControls;
}

private typedef PackageOptions = {
	final projectPath:String;
	final locked:Bool;
}

private typedef AddOptions = {
	final projectPath:String;
	final name:Null<String>;
	/** A Git dependency's URL and ref, or null for a registry dependency. */
	final git:Null<String>;
	final rev:Null<String>;
	/** A registry dependency's registry (default `haxeon`) and version range (default: from its latest release). */
	final registry:Null<String>;
	final version:Null<String>;
}

private typedef PublishOptions = {
	final projectPath:String;
	final registry:String;
	final version:String;
}

/** What `build` does with the project once it is resolved. */
private enum BuildCommand {
	Build;
	Run;

	/** Build the project's tests (the project in `tests`) and run them. */
	Test;

	/** Type the program without writing a module. */
	Check;

	/** Describe the project's public API, as `Check` types it (docs/design/API_MODEL.md). */
	Doc;
}

private typedef CommandCapture = {
	final status:Int;
	final output:String;
}

/** Project-facing build and launch commands for Haxeon applications. */
class HaxeonCli {
	/** The directory the user started the CLI from: a launched program runs in its project's directory and learns this one from `HAXEON_INVOKED_FROM`. */
	static var invokedFrom = "";

	/** Set by `haxeon script.hx`: the program runs in the directory the command was invoked from. */
	static var scriptRun = false;

	/** Environment for a launched program: where the user started it from, unless the caller already said. */
	static function launchEnvironment():Map<String, String> {
		var environment = new Map<String, String>(),
			existing = Sys.getEnv("HAXEON_INVOKED_FROM");
		if (existing == null || existing == "")
			environment.set("HAXEON_INVOKED_FROM", invokedFrom);
		return environment;
	}

	public static function main():Void
		run(Sys.args());

	/** The CLI with `arguments` (a command and its own), from the VM (`main`) or the executable built ahead of time. */
	public static function run(arguments:Array<String>):Void {
		invokedFrom = Sys.getCwd();
		while (invokedFrom.length > 1 && StringTools.endsWith(invokedFrom, "/"))
			invokedFrom = invokedFrom.substr(0, invokedFrom.length - 1);
		if (arguments.length == 0) {
			usage();
			Sys.exit(2);
		}

		var command = arguments.shift();
		var help = requestedHelp(command, arguments);
		if (help != null) {
			Sys.println(help);
			Sys.exit(0);
		}
		try {
			var status = switch command {
				case "create": ProjectCreator.run(arguments, haxeonHome());
				case "migrate": migrate(arguments);
				case "add": add(arguments);
				case "install": install(arguments);
				case "update": update(arguments);
				case "tree": tree(arguments);
				case "why": why(arguments);
				case "identity-path": IdentityPath.run(arguments, args -> build(args, Build));
				case "publish": publish(arguments);
				case "package": packageCommand(arguments);
				case "doctor": doctor(arguments);
				case "platforms": platforms(arguments);
				case "devices": devices(arguments);
				case "fmt": fmt(arguments);
				case "lint":
					var stdlib = HaxeonSdk.stdlib(haxeonHome());
					LintCommand.run(arguments, stdlib,
						(rule, files) -> runCompilerRole("lint", "LintMain", ['--stdlib=$stdlib', rule].concat(files)));
				case "build": build(arguments, Build);
				case "check": build(arguments, Check);
				case "doc": build(arguments, Doc);
				case "test": build(arguments, Test);
				case "clean": clean(arguments);
				case "run" if (arguments.length > 0 && ScriptRun.isScript(arguments[0])):
					runScript(arguments[0], arguments.slice(1));
				case "run": build(arguments, Run);
				case "workspace": workspaceCommand(arguments);
				case "heap": HeapInspector.run(arguments);
				case "lsp": languageServer(arguments);
				case "ffi": ffi(arguments);
				case "dev": tools.dev.DevCommand.run(arguments, haxeonHome());
				case "__generate-shaders": ShaderBuild.run(arguments, haxeonHome());
				case "version", "--version": version();
				case "help" if (arguments.length > 0): commandHelp(arguments.join(" "));
				case "help", "--help", "-h": usage();
				case _ if (ScriptRun.isScript(command)): runScript(command, arguments);
				case _ if (HaxeArguments.isHaxeArgument(command)): haxeCommandLine([command].concat(arguments));
				case _:
					unknownCommand(command);
					2;
			};
			// Digests a command made outside a build (`doctor`, `lsp`, `dev aot-compiler`) are kept for the next.
			DigestStore.saveShared();
			Sys.exit(status);
		} catch (error:Dynamic) {
			Sys.stderr().writeString("haxeon: " + (expectedFailure(error) ? "" : "internal error: ") + Std.string(error)
				+ "\n");
			Sys.exit(exitStatus(error));
		}
	}

	/**
	 * A failure the CLI reports for what the user asked or has (a usage error, a missing file, a failed step), not a bug in it:
	 * the CLI's own errors and the runtime's I/O errors. Any other exception (a haxe.exceptions one, say) is a bug.
	 */
	static function expectedFailure(error:Dynamic):Bool
		return !Std.isOfType(error, haxe.Exception) || Std.isOfType(error, UsageError)
			|| Std.isOfType(error, InternalError)
			|| Std.isOfType(error, compiler.core.Diagnostic.CompileError)
			|| Std.isOfType(error, compiler.formatter.TokenPreservation.TokenMismatch);

	/** 2 for a usage error, 1 for a failure, 70 (EX_SOFTWARE) for an error the CLI did not expect. */
	static function exitStatus(error:Dynamic):Int
		return Std.isOfType(error, UsageError)
			|| Std.isOfType(error, compiler.formatter.TokenPreservation.TokenMismatch)
			? 2 : (expectedFailure(error) ? 1 : 70);

	/** The target `--target` names; a name that is none is a usage error that lists the valid ones. */
	static function parseTarget(value:String):Target
		return try Target.parse(value) catch (error:haxe.Exception) throw new UsageError(error.message);

	/** `haxeon migrate [--project PATH] [--dry-run]`: the project's haxeon.json rewritten as the haxeon.toml that replaces it. */
	static function migrate(arguments:Array<String>):Int {
		var projectPath = ".", dryRun = false, index = 0;
		while (index < arguments.length) {
			var argument = arguments[index++];
			if (argument == "--dry-run")
				dryRun = true;
			else if (argument == "--project") {
				if (index >= arguments.length)
					throw new UsageError('Option "--project" requires a value');
				projectPath = arguments[index++];
			} else if (StringTools.startsWith(argument, "--project="))
				projectPath = argument.substr("--project=".length);
			else
				throw new UsageError('Unknown migrate option "$argument"');
		}
		var manifestPath = projectManifest(projectPath);
		if (PackageManifest.isToml(manifestPath))
			throw new UsageError(FileSystem.exists(manifestPath)
				? '$manifestPath is already TOML' : 'Project file not found: $manifestPath');
		if (!FileSystem.exists(manifestPath))
			throw new InternalError('Project file not found: $manifestPath');
		var tomlPath = Path.join([Path.directory(manifestPath), PackageManifest.TOML_NAME]);
		if (FileSystem.exists(tomlPath))
			throw new UsageError('${Path.directory(manifestPath)} has both ${PackageManifest.TOML_NAME} and ${PackageManifest.JSON_NAME}; keep one');
		var toml = PackageManifest.migrateToToml(manifestPath, File.getContent(manifestPath));
		if (dryRun) {
			Sys.print(toml);
			return 0;
		}
		File.saveContent(tomlPath, toml);
		FileSystem.deleteFile(manifestPath);
		Sys.println('Migrated ${displayPath(manifestPath)} to ${displayPath(tomlPath)}');
		return 0;
	}

	/**
	 * `haxeon fmt [--check] PATH... | --stdin`. Each file is formatted with its project's setting (ProjectFormat: the `format` section
	 * of the nearest haxeon.toml or haxeon.json, else tabs and 120 columns); --stdin uses the current directory's.
	 */
	static function fmt(arguments:Array<String>):Int {
		var check = false, stdin = false, paths:Array<String> = [];
		for (argument in arguments)
			if (argument == "--check")
				check = true;
			else if (argument == "--stdin")
				stdin = true;
			else if (StringTools.startsWith(argument, "-"))
				throw new UsageError('Unknown fmt option "$argument" (indentation and line width come from the [format] section of haxeon.toml or haxeon.json)');
			else
				paths.push(argument);
		if (stdin && paths.length > 0)
			throw new UsageError('haxeon fmt --stdin cannot be combined with file paths');
		if (!stdin && paths.length == 0)
			throw new UsageError('haxeon fmt requires a file path or --stdin');
		var projects = new ProjectFormat();
		if (stdin) {
			var source = Sys.stdin().readAll().toString(),
				formatted = Formatter.format(source, projects.forFile(Path.join([Sys.getCwd(), "<stdin>"])), null, null,
					"<stdin>");
			if (formatted == null)
				throw new InternalError("cannot format source from stdin: it does not lex or its brackets do not balance");
			if (check)
				return formatted == source ? 0 : 1;
			Sys.print(formatted);
			return 0;
		}
		var status = 0;
		for (path in SourceFiles.expand(paths)) {
			var source = File.getContent(path);
			var formatted:Null<String>;
			try {
				formatted = Formatter.format(source, projects.forFile(path), null, null, path);
			} catch (error:compiler.formatter.TokenPreservation.TokenMismatch) {
				Sys.stderr().writeString(error.message + "\n");
				status = 2;
				continue;
			}
			if (formatted == null) {
				Sys.stderr().writeString('Cannot format $path: it does not lex or its brackets do not balance\n');
				status = 2;
				continue;
			}
			if (formatted == source)
				continue;
			if (check) {
				Sys.println('Would reformat $path');
				if (status == 0)
					status = 1;
			} else
				File.saveContent(path, formatted);
		}
		return status;
	}

	static function add(arguments:Array<String>):Int {
		var options = parseAddOptions(arguments),
			manifestPath = projectManifest(options.projectPath);
		if (!FileSystem.exists(manifestPath))
			throw new InternalError('Project file not found: $manifestPath');
		var name = options.name == null ? inferPackageName(options.git) : options.name;
		if (name == null || name.length == 0)
			throw new UsageError('Git dependencies require a package name (pass it as the final argument or with --name)');
		var source:Dynamic, added:String;
		if (options.git != null) {
			source = {git: options.git, rev: options.rev};
			added = 'Added Git dependency ${name}@${options.rev}';
		} else {
			var registry = options.registry == null ? PackageSourceCodec.DEFAULT_REGISTRY : options.registry,
				range = options.version == null ? "^" + registryIndex(registry,
					name).latest(name).version : options.version;
			// A dependency on the default registry is written as its version range alone: `ui = "^0.3.0"`.
			source = registry == PackageSourceCodec.DEFAULT_REGISTRY ? range : {registry: registry, version: range};
			added = 'Added ${name} ${range} from the "$registry" registry';
		}
		if (PackageManifest.isToml(manifestPath))
			addTomlDependency(manifestPath, name, source);
		else {
			var raw = PackageManifest.decode(manifestPath, File.getContent(manifestPath)),
				dependencies:Dynamic = Reflect.field(raw, "dependencies");
			if (dependencies == null) {
				dependencies = {};
				Reflect.setField(raw, "dependencies", dependencies);
			}
			if (!Reflect.isObject(dependencies) || Std.isOfType(dependencies, Array))
				throw new InternalError('$manifestPath "dependencies" must be an object');
			if (Reflect.hasField(dependencies, name))
				throw new InternalError('Dependency "$name" is already declared in $manifestPath');
			Reflect.setField(dependencies, name, source);
			File.saveContent(manifestPath, Json.stringify(raw, null, "\t") + "\n");
		}
		Sys.println(added);
		return 0;
	}

	/** The index of `registry` that `name` resolves from: the SDK's for the haxeon registry, else the source cache's. */
	static function registryIndex(registry:String, name:String):RegistryIndex
		return ProjectDiscovery.sourceAcquirer().registry.index(registry, name);

	/**
	 * Adds `name = { ... }` to a haxeon.toml's `[dependencies]` section (made at the end when there is none), keeping the rest of
	 * the file, comments included, as it is. The result must read back as a manifest that declares the dependency.
	 */
	static function addTomlDependency(manifestPath:String, name:String, source:Dynamic):Void {
		var content = File.getContent(manifestPath),
			dependencies:Dynamic = Reflect.field(PackageManifest.decode(manifestPath, content), "dependencies");
		if (dependencies != null && Reflect.hasField(dependencies, name))
			throw new InternalError('Dependency "$name" is already declared in $manifestPath');
		var wrapper:Dynamic = {}, declared:Dynamic = {};
		Reflect.setField(declared, name, source);
		Reflect.setField(wrapper, "dependencies", declared);
		// The printed document is the section header, then the entry.
		var line = PackageManifest.toToml(wrapper).split("\n")[1],
			lines = content.split("\n"),
			section = -1;
		for (index in 0...lines.length)
			if (StringTools.trim(lines[index].split("#")[0]) == "[dependencies]")
				section = index;
		if (section < 0) {
			while (lines.length > 0 && StringTools.trim(lines[lines.length - 1]) == "")
				lines.pop();
			lines = lines.concat(["", "[dependencies]", line, ""]);
		} else {
			var end = section + 1;
			while (end < lines.length && !StringTools.startsWith(StringTools.trim(lines[end]), "["))
				end++;
			while (end > section + 1 && StringTools.trim(lines[end - 1]) == "")
				end--;
			lines.insert(end, line);
		}
		var updated = lines.join("\n"), problem = "the result does not declare it";
		var declares = try PackageManifest.parse(manifestPath,
			updated).dependencies.exists(name) catch (error:Dynamic) {
				problem = Std.string(error);
				false;
			}
		if (!declares)
			throw new InternalError('Could not add "$name" to $manifestPath ($problem); add `$line` to its dependencies by hand');
		File.saveContent(manifestPath, updated);
	}

	static function install(arguments:Array<String>):Int {
		var options = parsePackageOptions(arguments, true, "install"),
			manifestPath = projectManifest(options.projectPath),
			lockPath = lockfilePath(manifestPath),
			lockfile = FileSystem.exists(lockPath) ? PackageLockfile.parse(lockPath, File.getContent(lockPath)) : null;
		if (options.locked && lockfile == null)
			throw new InternalError('haxeon.lock is required for "haxeon install --locked"');
		var project = resolveProject(manifestPath, lockfile, options.locked);
		if (!options.locked)
			project.lockfile.save(lockPath);
		Sys.println('${options.locked ? "Validated" : "Installed"} ${project.packages.packages.length} packages');
		return 0;
	}

	static function update(arguments:Array<String>):Int {
		var options = parsePackageOptions(arguments, false, "update"),
			manifestPath = projectManifest(options.projectPath),
			project = resolveProject(manifestPath, null, false);
		project.lockfile.save(lockfilePath(manifestPath));
		Sys.println('Updated ${project.packages.packages.length} packages');
		return 0;
	}

	static function publish(arguments:Array<String>):Int {
		var options = parsePublishOptions(arguments),
			manifestPath = projectManifest(options.projectPath),
			checksum = RegistryPublisher.publish(manifestPath,
				Path.join([SourceCache.registryRoot(), TextDigest.sha256(options.registry)]),
				PackageManifest.parse(manifestPath, File.getContent(manifestPath)).packageName, options.version, []);
		Sys.println('Published ${options.version} from $manifestPath to ${options.registry} (checksum $checksum)');
		return 0;
	}

	static function packageCommand(arguments:Array<String>):Int {
		if (arguments.length == 0 || arguments[0] != "check")
			throw new UsageError('Usage: haxeon package check [--project PATH]');
		var options = parsePackageOptions(arguments.slice(1), false, "package check"),
			manifestPath = projectManifest(options.projectPath),
			project = discoverProject(manifestPath),
			target = Target.parse(project.manifest.target);
		NativeTargetSupport.validate(project, target);
		Sys.println('Package graph for ${project.rootPackage.name} [${target.toString()}]');
		for (resolvedPackage in project.packages.packages) {
			var native = resolvedPackage.manifest.native == null ? "none" : resolvedPackage.manifest.native.cmake
				!= null ? "cmake" : "sources";
			Sys.println('  ${resolvedPackage.name} ${PackageSourceTools.describe(resolvedPackage.source)} native:$native');
		}
		if (FileSystem.exists(lockfilePath(manifestPath)))
			Sys.println("  lockfile: validated");
		else
			Sys.println("  lockfile: not present");
		return 0;
	}

	static function tree(arguments:Array<String>):Int {
		var options = parsePackageOptions(arguments, false, "tree"),
			manifestPath = projectManifest(options.projectPath),
			project = discoverProject(manifestPath);
		printTree(project.rootPackage, project, "", new Map());
		return 0;
	}

	static function why(arguments:Array<String>):Int {
		var projectPath = ".", packageName:Null<String> = null, index = 0;
		while (index < arguments.length) {
			var argument = arguments[index++];
			if (argument == "--project") {
				if (index >= arguments.length)
					throw new UsageError('Option "--project" requires a value');
				projectPath = arguments[index++];
			} else if (StringTools.startsWith(argument, "--project="))
				projectPath = argument.substr("--project=".length);
			else if (StringTools.startsWith(argument, "--"))
				throw new UsageError('Unknown why option "$argument"');
			else if (packageName == null)
				packageName = argument;
			else
				throw new UsageError('Unexpected why argument "$argument"');
		}
		if (packageName == null || packageName.length == 0)
			throw new UsageError('Usage: haxeon why <package> [--project PATH]');
		var project = discoverProject(projectManifest(projectPath)),
			path = packagePath(project.rootPackage, packageName, project, new Map());
		if (path == null)
			throw new InternalError('Package "$packageName" is not reachable from ${project.rootPackage.name}');
		Sys.println(path.join(" -> "));
		return 0;
	}

	static function doctor(arguments:Array<String>):Int {
		if (arguments.length != 0)
			throw new UsageError('Unexpected doctor argument "${arguments[0]}"');
		var home = haxeonHome(), suffix = executableSuffix(), source = HaxeonSdk.source(home);
		var hashlinkPath = Path.join([HashLinkPath.directory(home), "hl" + suffix]);
		var missingRequired = false;

		if (source == null)
			Sys.println('ok: Haxeon release ${HaxeonSdk.field(home, "version")} (${HaxeonSdk.field(home, "platform")}, $home)');
		// A checkout builds the compiler from its sources with the pinned Haxe; a release ships it built.
		if (source != null)
			missingRequired = reportPath("pinned Haxe compiler", Path.join([source, ".tools", "haxe", "haxe" + suffix]),
				true) || missingRequired;
		else if (AotCompiler.program(home) == null)
			missingRequired = reportPath("compiler", AotCompiler.bytecode(home), true) || missingRequired;
		missingRequired = reportPath("HashLink VM, with the Haxeon runtime", hashlinkPath, true) || missingRequired;
		if (!missingRequired && !RuntimeLibrary.skipped()) {
			var lacking = RuntimeLibrary.missing(home);
			if (lacking.length > 0) {
				Sys.println("stale: " + RuntimeLibrary.describe(home, lacking));
				missingRequired = true;
			}
		}
		if (source != null)
			reportPath("self-hosted compiler", Path.join([source, "bootstrap", "compiler.hl"]), false);
		var aot = AotCompiler.executable(home);
		if (FileSystem.exists(aot) && AotCompiler.current(home) == null)
			Sys.println('stale: CLI and compiler built ahead of time ($aot), not built from these sources; the VM runs them. '
				+ 'Rebuild it with "haxeon dev aot"');
		else if (source == null && !FileSystem.exists(aot))
			// A release cannot build it: `haxeon dev aot` needs the sources and the native build, which only a checkout has.
			Sys.println('not built: CLI and compiler built ahead of time ($aot); this release runs them on the VM from their '
				+ 'bytecode, which works the same with a slower start');
		else
			reportPath("CLI and compiler built ahead of time", aot, false);
		var bytecode = AotCompiler.bytecode(home);
		if (FileSystem.exists(bytecode))
			Sys.println(AotCompiler.currentShipped(home, AotCompiler.BYTECODE) != null
				? 'ok: compiler bytecode, which the VM runs without the compiler built ahead of time ($bytecode)'
				: 'stale: compiler bytecode ($bytecode), not built from these sources');
		// A program builds without them; an app, a package with C or C++ code and a build ahead of time need them. So a
		// missing tool names its install command but does not fail the check.
		if (ToolchainCheck.report()) {
			Sys.println("Apps, programs built ahead of time, and packages with C or C++ code need native build tools.");
			Sys.println(ToolchainCheck.installGuidance());
		}
		var androidSdk = androidSdkDirectory(home), ndk = androidVersion(home, "ndk");
		reportPath("Android SDK", androidSdk, false);
		if (ndk != null)
			reportPath('Android NDK $ndk', Path.join([androidSdk, "ndk", ndk]), false);
		reportPath("Android platform tools (adb)", androidExecutable(home, "adb"), false);
		reportPath("Android host AAR", Path.join([home, "platforms", "android", "haxeon-host.aar"]), false);
		if (missingRequired)
			Sys.stderr().writeString(source != null
				? "Run the repository's setup/bootstrap tools to install missing dependencies.\n"
				: "This release is incomplete: unpack its archive again.\n");
		return missingRequired ? 1 : 0;
	}

	static function reportPath(label:String, path:String, required:Bool):Bool {
		var exists = FileSystem.exists(path);
		Sys.println('${exists ? "ok" : (required ? "missing" : "not built")}: $label ($path)');
		return required && !exists;
	}

	static function platforms(arguments:Array<String>):Int {
		if (arguments.length != 0)
			throw new UsageError('Unexpected platforms argument "${arguments[0]}"');
		Sys.println("Targets (--target, and \"target\" in haxeon.toml):");
		Sys.println('  host     this machine (${Target.detectHost().toString()}): build and run HashLink bytecode (backend hl)');
		Sys.println("  android  Android (android-arm64): build an APK, install and launch it on a device (backend hl)");
		Sys.println("  wasm32, wasm-gc  WebAssembly: build a module or bundle a web app");
		Sys.println("An explicit OS-ARCH[-ABI] (linux-x86_64, macos-arm64, windows-x86_64-msvc) names a host by its platform.");
		Sys.println("Use \"haxeon devices\" to list connected Android devices.");
		return 0;
	}

	static function devices(arguments:Array<String>):Int {
		if (arguments.length != 0)
			throw new UsageError('Unexpected devices argument "${arguments[0]}"');
		var home = haxeonHome();
		configureAndroidEnvironment(home);
		var adb = androidExecutable(home, "adb");
		if (!FileSystem.exists(adb))
			throw new InternalError('Android adb is missing at $adb; ${androidInstallHint(home)}');
		var result = capture(adb, ["devices", "-l"]);
		Sys.print(result.output);
		return result.status;
	}

	/** `haxeon workspace plan`: lower every member project onto one graph and report what the merge saves. */
	static function workspaceCommand(arguments:Array<String>):Int {
		var subcommand = arguments.length == 0 ? "" : arguments.shift(),
			path = "materia.workspace.json",
			skipTags:Array<String> = [],
			only:Array<String> = [],
			showActions = false,
			jobs = cpuCount(),
			compilers = 3,
			noTestCache = false;
		if (subcommand != "plan" && subcommand != "build" && subcommand != "test")
			throw new UsageError('Usage: haxeon workspace plan|build|test [--workspace PATH] [--skip-tag TAG] [--only NAME] [--jobs N] [--compilers N] [--no-test-cache] [--actions]');
		var index = 0;
		while (index < arguments.length) {
			var argument = arguments[index++];
			if (argument == "--actions")
				showActions = true;
			else if (argument == "--no-test-cache")
				noTestCache = true;
			else if (argument == "--workspace" || argument == "--skip-tag" || argument == "--only"
				|| argument == "--jobs" || argument == "--compilers") {
				if (index >= arguments.length)
					throw new UsageError('Option "$argument" requires a value');
				var value = arguments[index++];
				if (argument == "--workspace")
					path = value;
				else if (argument == "--skip-tag")
					skipTags.push(value);
				else if (argument == "--only")
					only.push(value);
				else {
					var count = Std.parseInt(value);
					if (count == null || count < 1)
						throw new UsageError('Option "$argument" requires a positive integer');
					if (argument == "--jobs")
						jobs = count;
					else
						compilers = count;
				}
			} else
				throw new UsageError('Unknown workspace option "$argument"');
		}
		var workspace = WorkspaceManifest.load(resolvePath(path, Sys.getCwd())),
			selected = [for (member in workspace.projects) {
				var skipped = only.length > 0 ? only.indexOf(member.name) < 0 : false;
				for (tag in skipTags)
					if (member.hasTag(tag))
						skipped = true;
				if (!skipped) member;
			}];
		if (selected.length == 0)
			throw new InternalError("No workspace projects selected");
		var started = Sys.time() * 1000.0,
			lowered = WorkspaceBuild.lower(workspace, selected, manifest -> discoverProject(manifest), haxeonHome(),
				[]),
			elapsed = Sys.time() * 1000.0 - started;
		if (subcommand != "plan") {
			var execution = subcommand == "test" ? WorkspaceBuild.withTests(lowered, haxeonHome(),
				!noTestCache) : lowered.plan,
				executor = new Executor(lowered.environment, jobs);
			executor.maxConcurrentCompilers = compilers;
			var ninja = NativeCMakeProvider.ninjaExecutable(haxeonHome()),
				server:Null<JobServer> = null;
			if (NativeCMakeProvider.ninjaSupportsJobserver(ninja))
				server = JobServer.start(Path.join([lowered.environment.buildRoot, ".haxeon"]), jobs);
			executor.jobServer = server;
			Sys.println('Workspace ${subcommand}: ${selected.length} projects, ${execution.actions.length} actions, $jobs jobs (planned in ${Std.int(elapsed)} ms)');
			Sys.println(server != null ? 'Job server: $jobs tokens shared with Ninja'
				: 'Job server: off (needs Ninja 1.13+; native builds use their own parallelism)');
			var result:build.execution.ActionResult.ExecutionResult;
			try {
				result = executor.execute(execution);
			} catch (error:haxe.Exception) {
				if (server != null)
					server.stop();
				throw error;
			}
			if (server != null)
				server.stop();
			var failed = [for (item in result.actions) if (!item.succeeded()) item];
			if (subcommand == "test") {
				var tests = [
					for (item in result.actions)
						if (StringTools.startsWith(item.id.key(), "test:")) item
				];
				Sys.println("Tests:");
				for (item in tests)
					Sys.println('  ${item.succeeded() ? (item.skipped ? "pass (cached)" : "pass") : (item.blocked ? "blocked" : "FAIL")}  ${item.id.key().substr(5)}');
			}
			var timed = [for (item in result.actions) if (item.elapsedMs > 0) item];
			timed.sort((left, right) -> left.elapsedMs > right.elapsedMs
				? -1 : (left.elapsedMs < right.elapsedMs ? 1 : 0));
			Sys.println("Slowest actions:");
			for (item in timed.slice(0, 8))
				Sys.println('  ${Std.int(item.elapsedMs / 1000)}s  ${item.id.key()}');
			Sys.println('${failed.length == 0 ? "OK" : "FAILED (" + failed.length + " actions)"} in ${Std.int(result.elapsedMs / 1000)}s');
			return failed.length == 0 ? 0 : (result.exitCode == 0 ? 1 : result.exitCode);
		}
		var shared = [
			for (action in lowered.plan.actions)
				if ((lowered.requestedBy.get(action.id.key()) ?? []).length > 1) action
		],
			cmake = [
				for (action in lowered.plan.actions)
					if (StringTools.startsWith(action.id.key(), "native-cmake-")) action
			];
		Sys.println('Workspace ${workspace.path}: ${selected.length} projects');
		for (member in lowered.projects)
			Sys.println('  ${member.name}: ${member.actions.length} actions');
		Sys.println('Actions: ${lowered.rawActionCount} requested -> ${lowered.plan.actions.length} after merging (${lowered.rawActionCount - lowered.plan.actions.length} shared)');
		Sys.println('CMake actions: ${cmake.length} (each project would otherwise run its own)');
		if (shared.length > 0) {
			Sys.println("Shared actions:");
			for (action in shared) {
				var users = lowered.requestedBy.get(action.id.key()) ?? [];
				Sys.println('  ${action.id}  x${users.length}: ${users.join(", ")}');
			}
		}
		if (showActions)
			Sys.print(lowered.plan.toDebugString());
		Sys.println('Planned in ${Std.int(elapsed)} ms');
		return 0;
	}

	/** Worker count for whole-workspace builds; falls back to 4 where `nproc` is unavailable. */
	static function cpuCount():Int {
		try {
			var process = new sys.io.Process("nproc"),
				output = StringTools.trim(process.stdout.readAll().toString()),
				status = process.exitCode();
			process.close();
			var count = Std.parseInt(output);
			if (status == 0 && count != null && count > 0)
				return count;
		} catch (_:Dynamic) {}
		return 4;
	}

	/** `haxeon ffi import|audit ...`: the C and C++ header importer and the cross-target C ABI auditor. */
	static function ffi(arguments:Array<String>):Int {
		var command = arguments.length == 0 ? "" : arguments.shift();
		return switch command {
			case "import": runCompilerRole("ffi-import", "FfiImportMain", arguments);
			case "audit": runCompilerRole("ffi-audit", "FfiAuditMain", arguments);
			case _: throw new UsageError('Usage: haxeon ffi import|audit ... (unknown ffi command "$command")');
		};
	}

	/**
	 * Runs a tool that carries the compiler with it (the language server, the typed lint rules, the FFI tools), with the
	 * command's standard streams and directory, and returns its status. This CLI does not contain them, which would make
	 * every command's start several times slower. It runs `role` of the compiler's program (`tools.CompilerExecutable`) when
	 * one is current (`build.AotCompiler.program`: the executable built ahead of time, or a release's compiler bytecode);
	 * else, in a checkout, the entry point `main` as a HashLink build of its own, from the tool cache (`haxeon dev tool-path`).
	 */
	static function runCompilerRole(role:String, main:String, arguments:Array<String>):Int {
		var home = haxeonHome(), program = AotCompiler.program(home);
		if (program != null)
			return Sys.command(program.command[0], program.command.slice(1).concat([role]).concat(arguments));
		if (HaxeonSdk.isRelease(home))
			throw new InternalError('This Haxeon release has no current compiler to run (${AotCompiler.bytecode(home)}); '
				+ "install the release again");
		return new tools.dev.ToolArtifacts(HaxeonSdk.requireSource(home, "This command")).run({
			main: main,
			classPaths: [],
			defines: []
		}, arguments);
	}

	/** `haxeon lsp`: the language server, given its SDK's standard library. */
	static function languageServer(arguments:Array<String>):Int {
		var home = haxeonHome();
		return runCompilerRole("lsp", "LspMain", ['--stdlib=${HaxeonSdk.stdlib(home)}'].concat(arguments));
	}

	/** `haxeon script.hx [arguments]`: build quietly, then run in the invoking directory (ScriptRun). */
	static function runScript(script:String, arguments:Array<String>):Int {
		scriptRun = true;
		var program = ScriptRun.program(script);
		// The program finds its own file through haxeon.Script.path().
		Sys.putEnv("HAXEON_SCRIPT", Path.normalize(FileSystem.fullPath(script)));
		// Each line out as it is printed, as a shell script's, also into a pipe or a CI log (unless the caller chose).
		if (Sys.getEnv("HL_STDOUT_FLUSH") == null)
			Sys.putEnv("HL_STDOUT_FLUSH", "1");
		return buildWith(programOptions("development", Verbosity.Minimal, false, true, arguments), Run, program);
	}

	/** Ends a `--quiet` build's capture, printing what it kept to standard error when the build failed. */
	static function releaseQuietOutput(options:BuildOptions, failed:Bool):Void {
		if (!options.quiet)
			return;
		var lines = BuildOutput.release();
		if (failed)
			for (line in lines)
				Sys.stderr().writeString(line + "\n");
	}

	/**
	 * The line a `minimal` build starts with, `Building NAME (TARGET, MODE)…` (`Checking NAME (TARGET)…` for a check); none for a
	 * plan or a `--quiet` build. Returns when the build started.
	 */
	static function announceBuild(options:BuildOptions, project:ResolvedProject, target:String, mode:String,
			check = false):Float {
		if (!options.plan && !options.quiet && options.verbosity.atLeast(Verbosity.Minimal))
			BuildOutput.line(check ? 'Checking ${project.rootPackage.name} ($target)\u2026'
				: 'Building ${project.rootPackage.name} ($target, $mode)\u2026');
		return Sys.time();
	}

	/**
	 * The line a `minimal` build ends with: what it wrote (or `done`, for a check, which writes nothing) and how long it took, or
	 * that it failed.
	 */
	static function reportBuilt(options:BuildOptions, output:Null<String>, status:Int, started:Float,
			?done:String):Void {
		if (options.plan || options.quiet || !options.verbosity.atLeast(Verbosity.Minimal))
			return;
		var tenths = Math.round((Sys.time() - started) * 10),
			seconds = ' (${Std.int(tenths / 10)}.${tenths % 10} s)';
		if (status != 0)
			BuildOutput.error('\u2718 ${done == null ? "Build" : "Check"} failed$seconds');
		else if (done != null)
			BuildOutput.line('\u2714 $done$seconds');
		else if (output != null)
			BuildOutput.line('\u2714 ${displayPath(output)}$seconds');
	}

	/** `path` as the user would type it: relative to the directory the command was run from when it lies below it. */
	static function displayPath(path:String):String {
		var normalized = Path.normalize(path), base = Path.normalize(invokedFrom);
		return StringTools.startsWith(normalized, base + "/") ? normalized.substr(base.length + 1) : normalized;
	}

	/** `haxeon build`, `run`, `test` and `check`, of the project the options name. */
	static function build(arguments:Array<String>, command:BuildCommand):Int {
		var options = parseBuildOptions(arguments);
		if (options.standardLibrary && command != Doc)
			throw new UsageError('Option "--standard-library" is only valid with "haxeon doc"');
		return buildWith(options, command, options.standardLibrary ? standardLibraryProgram() : null);
	}

	/**
	 * What `haxeon doc --standard-library` builds: a program with no sources of its own, whose description is the standard
	 * library's, each module of it (`--api-standard-library`), written to `build/api.json` in the directory it was run from unless
	 * `--output` says where. The standard library requires its documentation, as a package that says so does.
	 */
	static function standardLibraryProgram():ProgramProject {
		var directory = ProgramProject.directory("standard-library", null, "doc");
		return new ProgramProject(directory,
			PackageManifest.program("standard-library", null, [], [directory], true, [], null, [], null, true));
	}

	/**
	 * Builds the project the options name, or `program`, a project made in memory (a script's, a Haxe command line's), which is
	 * resolved in its cache directory and whose module is copied to its `publishTo` once built.
	 */
	static function buildWith(options:BuildOptions, command:BuildCommand, ?program:ProgramProject):Int {
		var launch = command == Run || command == Test,
			projectConfigPath = program != null ? program.manifestPath() : projectManifest(options.projectPath);
		if (command == Test && program == null)
			projectConfigPath = testProject(projectConfigPath);
		if (program == null && !FileSystem.exists(projectConfigPath))
			throw new InternalError('Project file not found: $projectConfigPath (run "haxeon create . --template console" to create one)');
		var requestedTarget:Null<Target> = options.target == null ? null : parseTarget(options.target);
		// A checkout whose compiler built ahead of time is stale says so once, unless the build prints no progress.
		AotCompiler.announceStale = !options.quiet && !options.plan && options.verbosity.atLeast(Verbosity.Minimal);
		function resolveProject():ResolvedProject
			return program != null ? ProjectDiscovery.resolve(projectConfigPath, requestedTarget, false,
				program.manifest) : discoverProject(projectConfigPath, requestedTarget);
		var resolveStarted = Sys.time() * 1000.0,
			project = resolveProject(),
			resolutionMs = Sys.time() * 1000.0 - resolveStarted,
			target = options.target == null ? project.manifest.target : options.target,
			targetInfo = requestedTarget == null ? Target.parse(target) : requestedTarget;
		if (command == Check || command == Doc) {
			if (options.debugPort != null || options.launchPlan != null)
				throw new UsageError('"--debug-port" and "--launch-plan" require "haxeon run"');
			return check(options, project, targetInfo, resolutionMs, command == Doc);
		}
		if (launch && targetInfo.isWasm())
			throw new InternalError('Use "haxeon build --target $target" to build for WebAssembly.');
		if (launch && targetInfo.equals(Target.detectHost()))
			RuntimeLibrary.requireCurrent(haxeonHome());
		if (options.plan && launch)
			throw new UsageError('Option "--plan" is only valid with "haxeon build"');
		if (options.explain && launch)
			throw new UsageError('Option "--explain" is only valid with "haxeon build"');
		if (options.compilerOnly && launch)
			throw new UsageError('Option "--compiler-only" is only valid with "haxeon build"');
		if (options.watch && !launch)
			throw new UsageError('Option "--watch" is only valid with "haxeon run"');
		if (options.restart && !options.watch)
			throw new UsageError('Option "--restart" requires "haxeon run --watch"');
		if (options.patchable && !(options.compilerOnly && !launch))
			throw new UsageError('Option "--patchable" is only valid with "haxeon build --compiler-only"');
		if (options.strictLive && (!options.watch || options.restart))
			throw new UsageError('Option "--strict-live" requires "haxeon run --watch" without "--restart"');
		// Every target goes through the structured build (HaxeonProjectBuild); an Android build then has Gradle package it.
		var hostBuild = targetInfo.equals(Target.detectHost())
			&& Target.parse(project.manifest.target).equals(Target.detectHost()),
			structuredBuild = hostBuild || targetInfo.isWasm() || targetInfo.isAndroid();
		if (options.watch && !targetInfo.isAndroid() && !hostBuild)
			throw new UsageError('Option "--watch" currently requires a host or Android project');
		if ((options.restart || options.strictLive) && targetInfo.isAndroid())
			throw new UsageError('The Android debug host patches every edit; "--restart" and "--strict-live" are for host projects');
		if ((options.debugPort != null || options.launchPlan != null)
			&& (command != Run || !hostBuild || options.watch || options.profile || options.buildMode != "development"))
			throw new UsageError('"--debug-port" and "--launch-plan" require a host development "haxeon run" without watching or profiling');
		if (command == Test && !hostBuild)
			throw new UsageError('"haxeon test" runs a host project\'s tests; "$target" is not the host');
		if (!launch && options.device != null)
			throw new UsageError('Option "--device" is only valid with "haxeon run --target android"');
		if (!targetInfo.isAndroid() && options.device != null)
			throw new UsageError('Option "--device" requires "--target android"');
		if (options.gradleInputs != null && (launch || !targetInfo.isAndroid()))
			throw new UsageError('Option "--gradle-inputs" is only valid with "haxeon build --target android"');
		if ((options.plan || options.explain || options.timings) && !structuredBuild)
			throw new UsageError('Plan, explanation, and timing output are available for host, wasm32 and android builds only');
		if (options.selfHosted && !structuredBuild)
			throw new UsageError('The self-hosted compiler is available for host, wasm32 and android builds only');
		if (options.profile && (!launch || !hostBuild))
			throw new UsageError('Profiling is currently available for "haxeon run" host builds only');
		// The instrument source runs the instrumented build flavor, which builds into a directory of its own.
		var instrument = options.profile && options.profileSources.indexOf("instrument") >= 0;
		ProfileCapture.controls = options.profileControls;
		ProfileCapture.minCallMicros = options.profileControls.minCallMicros != null
			? options.profileControls.minCallMicros : project.manifest.instrument.minCallMicros;
		if (options.profile && options.profileControls.start == "manual")
			Sys.println("haxeon: recording starts paused; the program starts it with haxeon.ProfileRecording.start() or toggle()");
		// The runtime installs the boundary hooks this asks for; the launched app inherits it.
		if (instrument)
			Sys.putEnv("HL_PROF_BOUNDARY", ProfileCapture.boundaryConfiguration(project.manifest.instrument));

		var home = haxeonHome(),
			app = program == null ? project.manifest.app : null,
			webHost = app != null && targetInfo.isWasm() ? AppRunner.webHost(project, home) : null;
		NativeTargetSupport.validate(project, targetInfo, webHost != null);
		if (hostBuild) {
			// An app builds through its runner project (docs/design/PROJECT_BUILDS.md); a script or another program as before.
			if (app != null && options.profile)
				throw new UsageError("Profiling an app through its runner is not supported yet");
			if (app != null && !options.plan && !options.compilerOnly)
				AppRunner.runnerDirectory(project, app, AppRunner.hostPlatform());
			var appScope = app != null && !options.compilerOnly ? BuildScope.Module : scope(options);
			// A release build is compiled ahead of time: its program is C, which an app's runner compiles into the app's
			// executable (docs/design/PROJECT_BUILDS.md) and which a console program's build compiles into one that ships with
			// its native libraries (`ConsoleProgram`). A development build keeps the JIT, which --watch patches.
			var consoleRelease = app == null && program == null && !options.compilerOnly
				&& options.buildMode == "release",
				aheadOfTime = options.buildMode == "release" && (app != null || consoleRelease);
			if (aheadOfTime && options.watch)
				throw new UsageError((app == null ? "A console program's" : "An app's")
					+ " release build is compiled ahead of time and cannot be watched or patched live; use the development build mode");
			if (consoleRelease && options.profile)
				throw new UsageError("Profiling a console program's release build is not supported yet; profile its development build");
			// A watch patches the app in the live host when its entry class has the host's entry points, unless told to restart.
			var live = options.patchable || options.watch && !options.restart && watchesLive(project, options);
			var buildDirectory = HaxeonProjectBuild.outputDirectory(project, instrument);
			// A program compiled ahead of time is C, written at `main.c/`.
			var output = options.output == null
				? Path.join([buildDirectory, "host", aheadOfTime ? "main" : "main.hl"]) : resolvePath(options.output,
				project.root),
				executable = consoleRelease ? ConsoleProgram.executablePath(buildDirectory, Target.detectHost(),
					project.rootPackage.name) : null;
			if (consoleRelease && !options.plan)
				ToolchainCheck.requireAheadOfTime();
			// A stamp left by an earlier compiler would pin the live host to that revision if this compiler (a bootstrap
			// one, say) writes none; without a stamp the host reads the description every tick.
			if (live && FileSystem.exists(output + ".live.stamp"))
				FileSystem.deleteFile(output + ".live.stamp");
			// A watching process keeps file hashes and its compiler worker choice between builds, starting with this one so the first
			// edit is already warm.
			var session = options.watch ? new BuildSession() : null;
			if (options.quiet)
				BuildOutput.capture();
			var started = announceBuild(options, project, "host", options.buildMode);
			var buildStatus = try HaxeonProjectBuild.build(project, home, output, options.defines, options.jobs,
				options.plan, options.explain, options.timings,
				resolutionMs, options.selfHosted, appScope, live, instrument, session,
				options.buildMode == "development", null, null, options.style,
				aheadOfTime, program == null ? null : program.scriptModule, null,
				consoleRelease) catch (error:haxe.Exception) {
					releaseQuietOutput(options, true);
					throw error;
				}
			if (app != null && buildStatus == 0 && !options.plan && !options.compilerOnly)
				buildStatus = AppRunner.build(project, home, AppRunner.hostPlatform(), output, aheadOfTime,
					options.quiet);
			var publishTo = program == null ? null : program.publishTo;
			if (buildStatus == 0 && publishTo != null && !options.plan) {
				ensureDirectory(Path.directory(publishTo));
				File.copy(output, publishTo);
			}
			reportBuilt(options, executable != null ? executable : publishTo == null ? output : publishTo, buildStatus,
				started);
			releaseQuietOutput(options, buildStatus != 0);
			if (buildStatus != 0 || !launch)
				return buildStatus;
			// Under the build's PATH, which chooses the worker the rebuilds will reach.
			if (live && session != null)
				session.warmLiveCompiler();
			// An app runs as its runner's executable and a console program's release as its own, each of which finds its native
			// libraries beside itself.
			var runner = app == null ? executable : AppRunner.executable(project, AppRunner.hostPlatform());
			var hashlink = runner != null
				? runner : Path.join([HashLinkPath.directory(home), "hl" + executableSuffix()]);
			if (!FileSystem.exists(hashlink))
				throw new InternalError(runner != null ? 'Executable is missing: $runner'
					: 'HashLink is missing: $hashlink (run scripts/build-native.sh)');
			var nativeDirectories = [
				for (resolvedPackage in project.packages.packages)
					if (resolvedPackage.nativeSources.length > 0
					|| (resolvedPackage.manifest.native != null
					&& resolvedPackage.manifest.native.cmake != null)) Path.join([
						buildDirectory,
						"host",
						"native",
						resolvedPackage.name
					])
			];
			var cwd = scriptRun ? invokedFrom : project.root,
				arguments:Array<String> = [];
			if (options.debugPort != null)
				arguments = runner == null ? ["--debug-wait", "--debug", Std.string(options.debugPort)]
					: ['--vm-debug-port=${options.debugPort}'];
			if (runner == null)
				arguments.push(output);
			arguments = arguments.concat(options.runtimeArguments);
			var environment = launchEnvironment(),
				libraryPath = consoleRelease ? null : runtimeLibraryPath(home, nativeDirectories);
			if (libraryPath != null)
				environment.set(libraryPath.name, libraryPath.value);
			if (options.launchPlan != null) {
				File.saveContent(resolvePath(options.launchPlan, invokedFrom), Json.stringify({
					command: hashlink,
					arguments: arguments,
					cwd: cwd,
					program: output,
					classPaths: [for (resolved in project.packages.packages) for (root in resolved.sourceRoots) root],
					environment: environment
				}));
				return 0;
			}
			// On Windows the app finds its libraries through PATH, but builds choose their compiler worker by a fingerprint
			// that includes PATH. Rebuilds keep the PATH the first build had, so they reach the same worker and its module
			// identity, and a live app can be patched instead of reloaded.
			var buildPath = environmentCopy("PATH");
			if (libraryPath != null)
				Sys.putEnv(libraryPath.name, libraryPath.value);
			var runPath = environmentCopy("PATH");
			if (options.watch) {
				var liveHost:Null<String> = null;
				// The live host inherits it and refuses unpatchable edits instead of reloading.
				if (options.strictLive)
					Sys.putEnv("HAXEON_LIVE_STRICT", "1");
				if (live) {
					// Under the build PATH, like the rebuilds below, so the host build reaches the same compiler worker.
					var swapPath = buildPath != null && runPath != null;
					if (swapPath)
						Sys.putEnv("PATH", buildPath);
					try
						liveHost = LiveHostBuild.program(home, options.jobs, instrument, session, options.style)
					catch (error:haxe.Exception) {
						if (swapPath)
							Sys.putEnv("PATH", runPath);
						throw error;
					}
					if (swapPath)
						Sys.putEnv("PATH", runPath);
				}
				// Each launch is profiled into its own capture, from launch to exit or relaunch.
				if (options.profileOutput != null && Path.extension(options.profileOutput) == "hlpc")
					throw new UsageError('With --watch, --profile-output names the directory that holds one capture per launch, not an .hlpc file');
				var profiling:Null<WatchProfiling> = options.profile ? {
					profiler: profilerTool(home),
					root: options.profileOutput == null ? Path.join([Path.directory(output), "profile"])
						: resolvePath(options.profileOutput, project.root),
					processName: project.manifest.entry,
					sources: options.profileSources
				} : null;
				// The resolved project is reused while edits only change Haxe file contents. The lockfile is not watched, so its stamp
				// is checked here.
				var cachedProject = project,
					cachedLock = lockfileStamp(projectConfigPath);
				return WatchRun.run(project, hashlink, output, options.runtimeArguments, liveHost,
					project.manifest.entry, profiling,
					function(change:WatchChange) {
						var windows = Sys.systemName() == "Windows" && buildPath != null;
						if (windows)
							Sys.putEnv("PATH", buildPath);
						try {
							// A project resolved again is kept even if its build fails: the next, content-only edit must not fall back to the
							// project from before the structural change.
							var lock = lockfileStamp(projectConfigPath);
							if (change.structural || lock != cachedLock) {
								cachedLock = null; // resolve again next time if this throws
								cachedProject = resolveProject();
								cachedLock = lock;
							}
							var candidate = cachedProject;
							var status = HaxeonProjectBuild.build(candidate, home, output, options.defines,
								options.jobs, false, false, false, 0.0,
								options.selfHosted, change.compilerOnly ? Edit : app != null
								? BuildScope.Module : Full, live,
								instrument, session,
								options.buildMode == "development", null, null, options.style);
							if (windows)
								Sys.putEnv("PATH", runPath);
							return status == 0 ? candidate : null;
						} catch (error:Dynamic) {
							if (windows)
								Sys.putEnv("PATH", runPath);
							Sys.stderr().writeString("haxeon: " + Std.string(error) + "\n");
							// The watch loop reports the failure from what the build printed.
							OutputCapture.record("haxeon: " + Std.string(error) + "\n");
							return null;
						}
					}, options.verbosity, session, runner != null, instrument);
			}
			if (options.profile) {
				var capture = options.profileOutput == null ? ProfileCapture.nextCapture(Path.join([
					Path.directory(output),
					"profile"
				])) : resolvePath(options.profileOutput,
					project.root);
				return runProfiled(home, output, options.runtimeArguments, project.root, capture,
					project.manifest.entry, options.profileSources);
			}
			if (!options.quiet && options.verbosity.atLeast(Verbosity.Normal))
				Sys.println('Launching ${runner != null ? runner : output}');
			// A script runs where it was invoked; a project in its root.
			var status = ProcessRunner.run(hashlink, arguments, cwd, environment);
			return command == Test ? testStatus(options, status) : status;
		}
		if (targetInfo.isWasm()) {
			var targetName = targetInfo.toString();
			if (app != null && !options.compilerOnly)
				AppRunner.runnerDirectory(project, app, "web");
			var output = options.output == null ? Path.join([
				HaxeonProjectBuild.outputDirectory(project, false),
				targetName,
				"main.wasm"
			]) : resolvePath(options.output, project.root);
			if (options.quiet)
				BuildOutput.capture();
			var started = announceBuild(options, project, targetName, options.buildMode);
			var buildStatus = try HaxeonProjectBuild.build(project, home, output, options.defines, options.jobs,
				options.plan, options.explain, options.timings, resolutionMs, options.selfHosted, scope(options),
				false,
				false, null, options.buildMode == "development",
				targetInfo, null, options.style, false, null, webHost) catch (error:haxe.Exception) {
					releaseQuietOutput(options, true);
					throw error;
				}
			releaseQuietOutput(options, buildStatus != 0);
			if (buildStatus == 0 && app != null && !options.plan && !options.compilerOnly)
				output = AppRunner.bundleWeb(project, app, home, targetInfo, output, webHost);
			reportBuilt(options, output, buildStatus, started);
			return buildStatus;
		}
		if (!targetInfo.isAndroid())
			throw new UsageError('Target "$target" cannot be built yet; build for the host, wasm32 or android');
		// The Android debug host always accepts live patches.
		if (options.buildModeExplicit && options.buildMode == "release")
			throw new UsageError("The Android live-patch host requires development build mode");
		if (app == null && !options.compilerOnly)
			throw new UsageError("Packaging for Android requires an app with an Android runner");
		var runner = app != null && !options.compilerOnly ? AppRunner.runnerDirectory(project, app, "android") : null,
			applicationId = app == null ? null : app.id;
		configureAndroidEnvironment(home);
		// A watch keeps the session so edits reach the compiler worker that built the module.
		var module = HaxeonProjectBuild.androidModulePath(project, targetInfo),
			session = options.watch ? new BuildSession() : null;
		if (options.quiet)
			BuildOutput.capture();
		var started = announceBuild(options, project, "android", "development");
		var buildStatus = try HaxeonProjectBuild.build(project, home, module, options.defines, options.jobs,
			options.plan, options.explain, options.timings, resolutionMs, options.selfHosted,
			options.compilerOnly ? scope(options) : BuildScope.Module,
			false, false, session, true, targetInfo, null, options.style) catch (error:haxe.Exception) {
				releaseQuietOutput(options, true);
				throw error;
			}
		// Gradle packages the module next, and says so itself.
		reportBuilt(options, options.compilerOnly ? module : null, buildStatus, started);
		releaseQuietOutput(options, buildStatus != 0);
		if (buildStatus != 0 || options.plan || options.compilerOnly)
			return buildStatus;
		var fragment = AppRunner.writeFragment(project, app, home, "android", module),
			gradleInputs = writeGradleInputs(project, app, home, module, Path.directory(fragment),
				options.gradleInputs);
		if (options.gradleInputs != null)
			return 0;
		var androidOutput = options.output == null ? Path.join([
			HaxeonProjectBuild.outputDirectory(project, false),
			"android",
			"app-debug.apk"
		]) : resolvePath(options.output, project.root);
		var status = buildAndroid(runner, androidOutput, gradleInputs, home);
		if (status != 0 || !launch)
			return status;
		var launched = installAndLaunchAndroid(home, androidOutput, applicationId,
			options.device);
		if (launched != 0 || !options.watch)
			return launched;
		// Each saved edit is compiled against the baseline this build wrote and sent to the running app (AndroidWatch).
		var adb = androidExecutable(home, "adb");
		var device = selectAndroidDevice(adb, options.device);
		return AndroidWatch.run(home, project, targetInfo, module, options.defines, options.jobs, options.selfHosted,
			session, adb, device);
	}

	/**
	 * Whether `haxeon run --watch` patches the app in the live host: its entry class declares every entry point the host calls.
	 * It says which way it chose, and why not live; `--strict-live` requires the live host.
	 */
	static function watchesLive(project:ResolvedProject, options:BuildOptions):Bool {
		var entry = project.manifest.entry, missing = LiveHostBuild.missingEntryPoints(project);
		if (missing.length > 0 && options.strictLive)
			throw new UsageError('Option "--strict-live" requires the live host, which calls static '
				+ '${LiveEntryPoints.REQUIRED.join(", ")} of the entry class; $entry does not declare ${missing.join(", ")}');
		// Live patching needs the development build's metadata.
		if (missing.length == 0 && options.buildModeExplicit && options.buildMode != "development")
			throw new UsageError('$entry can be patched live, which needs the development build mode; pass "--restart" to rebuild '
				+ 'and relaunch a release build on each edit');
		if (!options.quiet && options.verbosity.atLeast(Verbosity.Minimal))
			Sys.println(missing.length == 0
				? 'haxeon: edits patch the running app ($entry has the live entry points; --restart relaunches it instead)'
				: 'haxeon: edits relaunch the app ($entry does not declare ${missing.join(", ")} for live patching)');
		return missing.length == 0;
	}

	static function scope(options:BuildOptions):BuildScope
		return options.compilerOnly ? CompilerOnly : Full;

	/**
	 * `haxeon check`: types the project's program as a build would, for any target, and reports its diagnostics without writing a
	 * module. Only the compile runs, with the FFI imports it reads; it shares the build's compiler session, so a check after a
	 * build, or a build after a check, reuses what the other typed. With `describe` it is `haxeon doc`, which also writes the
	 * API model of the project's own modules, or of the standard library's (`--standard-library`), to `--output` (default
	 * `build/api.json`, of the project or of the directory it was run from).
	 */
	static function check(options:BuildOptions, project:ResolvedProject, target:Target, resolutionMs:Float,
			describe:Bool = false):Int {
		var name = describe ? "doc" : "check";
		if (options.plan || options.explain || options.compilerOnly || options.watch || options.restart
			|| options.patchable || options.strictLive
			|| options.profile || options.quiet || (options.output != null && !describe) || options.device != null
			|| options.gradleInputs != null || options.runtimeArguments.length > 0)
			throw new UsageError('haxeon $name takes only --project, --target, --build-mode, --define, --jobs, --timings, -v, --color'
				+ (describe ? ', --diagnostic-format and --output' : ' and --diagnostic-format')
				+ '. See \'haxeon $name --help\'.');
		var api:Null<build.lowering.LoweringContext.ApiDescription> = !describe ? null : {
			output: options.output != null ? resolvePath(options.output, invokedFrom) : Path.join([
				options.standardLibrary
					? Path.join([invokedFrom, "build"]) : HaxeonProjectBuild.outputDirectory(project, false),
				"api.json"
			]),
			standardLibrary: options.standardLibrary
		};
		var home = haxeonHome(),
			webHost = target.isWasm() && project.manifest.app != null ? AppRunner.webHost(project, home) : null;
		NativeTargetSupport.validate(project, target, webHost != null);
		var started = announceBuild(options, project,
			target.isWasm() ? target.toString() : (target.isAndroid() ? "android" : "host"),
			options.buildMode, true),
			// Nothing is written there: it names the check's source list, beside the build's, in the build's directory.
			output = Path.join([HaxeonProjectBuild.outputDirectory(project, false), name, "main"]),
			status = HaxeonProjectBuild.build(project, home, output, options.defines, options.jobs, false,
				false,
				options.timings, resolutionMs, false, Check, false, false, null, options.buildMode == "development",
				target,
				null, options.style, false, null, webHost, false, api);
		reportBuilt(options, api == null ? null : api.output, status, started, describe ? null : "No errors");
		return status;
	}

	/**
	 * The project `haxeon test` runs: the manifest in `tests` beside the project's file, where a package keeps its tests, or the
	 * project itself when it is that tests project (its directory is `tests`).
	 */
	static function testProject(manifestPath:String):String {
		var testsDirectory = Path.join([Path.directory(manifestPath), "tests"]),
			tests = FileSystem.isDirectory(testsDirectory) ? PackageManifest.find(testsDirectory) : null;
		if (tests != null)
			return tests;
		if (Path.withoutDirectory(Path.directory(manifestPath)) == "tests")
			return manifestPath;
		if (!FileSystem.exists(manifestPath))
			throw new InternalError('Project file not found: $manifestPath (run "haxeon create . --template console" to create one)');
		throw new InternalError('No tests for $manifestPath: a project keeps them in a project of their own, ${Path.join([testsDirectory, PackageManifest.TOML_NAME])}');
	}

	/** A test run's status: 0 when the tests passed, else 1, with a line that says which. */
	static function testStatus(options:BuildOptions, status:Int):Int {
		if (!options.quiet && options.verbosity.atLeast(Verbosity.Minimal)) {
			if (status == 0)
				BuildOutput.line("✔ Tests passed");
			else
				BuildOutput.error('✘ Tests failed (exit status $status)');
		}
		return status == 0 ? 0 : 1;
	}

	/**
	 * `haxeon clean`: removes the project's build directories (`outputDir`, and the instrumented flavor's beside it) and its tests
	 * project's. What projects share (compiler workers, the native and artifact caches) stays.
	 */
	static function clean(arguments:Array<String>):Int {
		var options = parsePackageOptions(arguments, false, "clean"),
			manifestPath = projectManifest(options.projectPath),
			directories:Array<String> = [];
		if (!FileSystem.exists(manifestPath))
			throw new InternalError('Project file not found: $manifestPath');
		var testsDirectory = Path.join([Path.directory(manifestPath), "tests"]),
			tests = FileSystem.isDirectory(testsDirectory) ? PackageManifest.find(testsDirectory) : null;
		directories = buildDirectories(manifestPath);
		if (tests != null)
			directories = directories.concat(buildDirectories(tests));
		var removed = 0;
		for (directory in directories)
			if (FileSystem.exists(directory)) {
				FileTree.remove(directory);
				Sys.println('Removed ${displayPath(directory)}');
				removed++;
			}
		if (removed == 0)
			Sys.println("Nothing to remove");
		return 0;
	}

	/** A project's build directories. One that would hold the project itself is refused, never removed. */
	static function buildDirectories(manifestPath:String):Array<String> {
		var manifest = PackageManifest.parse(manifestPath, File.getContent(manifestPath)),
			root = Path.normalize(Path.directory(manifestPath));
		return [for (suffix in ["", "-instrument"]) {
			var directory = resolvePath(manifest.outputDir + suffix, root);
			if (directory == root || StringTools.startsWith(root + "/", directory + "/"))
				throw new InternalError('The "outputDir" of $manifestPath is $directory, which holds the project; remove its build by hand');
			directory;
		}];
	}

	/**
	 * `haxeon build.hxml`, `haxeon -cp src -main Main --hl out.hl`: a Haxe command line (HaxeArguments), one compilation after
	 * another, stopping at the first that fails, as Haxe does. A compilation with nothing to compile prints the help, as Haxe's
	 * does, and the next one runs.
	 */
	static function haxeCommandLine(arguments:Array<String>):Int {
		for (compilation in HaxeArguments.parse(arguments, invokedFrom)) {
			var status = haxeCompilation(compilation);
			if (status != 0)
				return status;
		}
		return 0;
	}

	/**
	 * One compilation of a Haxe command line, as a program project (ProgramProject) built in the CLI's `hxml` cache
	 * (`HAXEON_HXML_CACHE`, else `~/.haxeon/cache/hxml`), in a directory named by the compilation's working directory, entry and
	 * output: the entry and the dot paths given are its sources, the class paths its source roots, and each `-lib NAME:VERSION`
	 * a Haxelib dependency. It builds in release mode (development with `--debug`), and its module is copied to `--hl FILE`;
	 * with no target, or `--no-output`, the program is only checked, as Haxe then only types it. Its `--macro nullSafety(...)`
	 * rules go to the compile as they are. Its `--cmd`s run after it succeeds.
	 */
	static function haxeCompilation(compilation:HaxeCompilation):Int {
		var main = compilation.main;
		if (main == null && compilation.modules.length == 0) {
			Sys.println(CliHelp.command("FILE.hxml"));
			return 0;
		}
		if (main == null)
			throw new UsageError("Haxeon builds a program from its entry: name it with -main CLASS");
		var sources = [];
		for (module in [main].concat(compilation.modules)) {
			var file = HaxeArguments.moduleFile(compilation, module);
			if (file == null) {
				// Haxe's own words, and its status for a compilation that fails.
				Sys.stderr().writeString('Type not found : $module\n');
				return 1;
			}
			sources.push(file);
		}
		var dependencies:Map<String, project.PackageSource> = [];
		for (library in compilation.libraries)
			dependencies.set(library.name, project.PackageSource.Haxelib(library.name, library.version));
		var output = compilation.noOutput ? null : compilation.hl,
			key = compilation.directory + "\n" + main + "\n" + (output == null ? "" : output),
			program = new ProgramProject(
				ProgramProject.directory("hxml", "HAXEON_HXML_CACHE",
					ContentDigest.makeHex(Bytes.ofString(key)).substr(0, 16)),
				// A class path holds any package, as Haxe's do.
				PackageManifest.program(main, main, sources, compilation.classPaths, false, compilation.defines,
					compilation.noInline ? false : null, dependencies, compilation.nullSafety),
				output
			),
			options = programOptions(compilation.debug ? "development" : "release",
				compilation.verbose ? Verbosity.Normal : Verbosity.Minimal, compilation.times, false, []);
		var status = buildWith(options, output == null ? Check : Build, program);
		if (status != 0)
			return status;
		for (command in compilation.commands) {
			var windows = Sys.systemName() == "Windows",
				result = ProcessRunner.run(windows ? "cmd" : "sh", [windows ? "/c" : "-c", command],
					compilation.directory,
					new Map());
			if (result != 0) {
				Sys.stderr().writeString('haxeon: command failed with status $result: $command\n');
				return 1;
			}
		}
		return 0;
	}

	static function pumpProcessOutput(input:haxe.io.Input, output:haxe.io.Output, done:sys.thread.Lock):Void {
		sys.thread.Thread.create(function() {
			runtime.ThreadName.setCurrent("haxeon.cli.pump");
			try {
				var bytes = haxe.io.Bytes.alloc(8192),
					count = input.readBytes(bytes, 0, bytes.length);
				while (count > 0) {
					output.writeBytes(bytes, 0, count);
					output.flush();
					count = input.readBytes(bytes, 0, bytes.length);
				}
			} catch (_:Dynamic) {}
			done.release();
		});
	}

	/** hlprof-live, which records and exports profiler captures. */
	static function profilerTool(home:String):String {
		var profiler = Path.join([HashLinkPath.directory(home), "hlprof-live" + executableSuffix()]);
		if (!FileSystem.exists(profiler))
			throw new InternalError('hlprof-live is missing: $profiler (rebuild the native runtime)');
		return profiler;
	}

	static function runProfiled(home:String, output:String, runtimeArguments:Array<String>, projectDirectory:String,
			capture:String, processName:String,
			sources:Array<String>):Int {
		var runtime = Path.join([HashLinkPath.directory(home), "hl" + executableSuffix()]),
			profiler = profilerTool(home);
		if (!FileSystem.exists(runtime))
			throw new InternalError('HashLink is missing: $runtime (run scripts/build-native.sh)');
		var profile = new ProfileCapture(profiler, capture, processName, sources),
			done = new sys.thread.Lock(),
			readers = 0;
		profile.keepBytecode(output);
		var app = new sys.io.Process(runtime, profile.runtimeArguments().concat([output]).concat(runtimeArguments));
		Sys.println('Profiling $output -> $capture (diagnostics port ${profile.port})');
		var profilerProcess = new sys.io.Process(profiler, profile.recorderArguments());
		// Start both processes before creating reader threads. Forking a second
		// process from the eval runtime while those threads are active can stall.
		pumpProcessOutput(app.stdout, Sys.stdout(), done);
		pumpProcessOutput(app.stderr, Sys.stderr(), done);
		readers += 2;
		pumpProcessOutput(profilerProcess.stdout, Sys.stdout(), done);
		pumpProcessOutput(profilerProcess.stderr, Sys.stderr(), done);
		readers += 2;
		var profilerStatus = profilerProcess.exitCode();
		profilerProcess.close();
		if (profilerStatus != 0)
			app.kill();
		var runtimeStatus = app.exitCode();
		app.close();
		for (_ in 0...readers)
			done.wait();
		Sys.stdout().flush();
		Sys.stderr().flush();
		if (profilerStatus != 0)
			throw new InternalError('Profiler capture did not finalize cleanly (status $profilerStatus)');
		var trace = profile.complete();
		Sys.println('Capture: $capture');
		if (trace != null)
			Sys.println('Perfetto trace: $trace (open it at https://ui.perfetto.dev)');
		ProcessRunner.run(profiler, ["report", "--top", "40", capture], projectDirectory, new Map());
		return runtimeStatus == 0 && trace == null ? 1 : runtimeStatus;
	}

	static function writeGradleInputs(project:ResolvedProject, app:AppManifest, home:String,
			module:String, generated:String, ?requested:String):String {
		function property(key:String, value:String):String
			return key + "=" + StringTools.replace(StringTools.replace(StringTools.replace(value, "\\", "\\\\"),
				"\r", "\\r"), "\n", "\\n") + "\n";
		var path = requested == null ? Path.join([generated, "inputs.properties"]) : requested,
			assets = Path.join([generated, "assets"]);
		ensureDirectory(assets);
		for (suffix in ["", ".hli", ".hcs"])
			File.copy(module + suffix, Path.join([assets, suffix == "" ? "app.hl" : "app" + suffix]));
		ensureDirectory(Path.directory(path));
		File.saveContent(path, property("generated", generated) + property("id", app.id) + property("name",
			app.name) + property("version", app.version)
			+ property("assets", assets)
			+ property("host", Path.join([home, "platforms", "android", "haxeon-host.aar"]))
			+ property("native",
			Std.string(Lambda.exists(project.packages.packages, resolved -> resolved.manifest.native != null))));
		return path;
	}

	static function buildAndroid(androidDirectory:String, output:String, gradleInputs:String, home:String):Int {
		var sdk = androidSdkDirectory(home), host = Path.join([home, "platforms", "android", "haxeon-host.aar"]);
		if (!FileSystem.exists(host))
			throw new InternalError('Android host AAR is missing at $host; use an SDK built with the Android toolchain');
		if (!FileSystem.exists(sdk))
			throw new InternalError('Android SDK is missing under $sdk; ${androidInstallHint(home)}');
		var wrapperJar = Path.join([androidDirectory, "gradle", "wrapper", "gradle-wrapper.jar"]);
		var arguments = [
			"-classpath",
			wrapperJar,
			"org.gradle.wrapper.GradleWrapperMain",
			"-p",
			androidDirectory,
			"--max-workers=2",
			"assembleDebug",
			"-PhaxeonInputs=" + gradleInputs
		];
		var status = ProcessRunner.run(javaExecutable(), arguments, Sys.getCwd(), new Map());
		if (status != 0)
			return status;

		var generated = Path.join([androidDirectory, "app", "build", "outputs", "apk", "debug", "app-debug.apk"]);
		if (!FileSystem.exists(generated))
			throw new InternalError('Gradle succeeded but did not create $generated');
		ensureDirectory(Path.directory(output));
		File.copy(generated, output);
		Sys.println('Built android -> $output');
		return 0;
	}

	static function installAndLaunchAndroid(home:String, apk:String, applicationId:String,
			requestedDevice:Null<String>):Int {
		configureAndroidEnvironment(home);
		var adb = androidExecutable(home, "adb");
		if (!FileSystem.exists(adb))
			throw new InternalError('Android adb is missing at $adb; ${androidInstallHint(home)}');
		var device = selectAndroidDevice(adb, requestedDevice);

		var status = ProcessRunner.run(adb, ["-s", device, "install", "-r", apk], Sys.getCwd(), new Map());
		if (status != 0)
			return status;
		ProcessRunner.run(adb, ["-s", device, "shell", "am", "force-stop", applicationId], Sys.getCwd(), new Map());
		Sys.println('Launching $applicationId on $device');
		return ProcessRunner.run(adb, ["-s", device, "shell", "monkey", "-p", applicationId, "1"], Sys.getCwd(),
			new Map());
	}

	/** The device to run on: the one asked for, which must be online, or the only one online. */
	static function selectAndroidDevice(adb:String, requestedDevice:Null<String>):String {
		var connected = onlineAndroidDevices(adb);
		if (requestedDevice == null) {
			if (connected.length == 0)
				throw new InternalError('No online Android device. Start an emulator or connect a device, then run "haxeon devices".');
			if (connected.length > 1)
				throw new InternalError('More than one Android device is connected; choose one with "--device SERIAL".');
			return connected[0].serial;
		}
		for (connectedDevice in connected)
			if (connectedDevice.serial == requestedDevice)
				return requestedDevice;
		throw new InternalError('Android device "$requestedDevice" is not online; run "haxeon devices" to inspect connected devices.');
	}

	static function onlineAndroidDevices(adb:String):Array<{serial:String, state:String}> {
		var result = capture(adb, ["devices"]);
		if (result.status != 0)
			throw new InternalError('Could not query Android devices: ${result.output}');
		var devices:Array<{serial:String, state:String}> = [];
		for (line in result.output.split("\n")) {
			var trimmed = StringTools.trim(line);
			if (trimmed.length == 0)
				continue;
			var fields = ~/\s+/.split(trimmed);
			if (fields.length >= 2 && fields[0] != "List" && fields[0].length > 0)
				devices.push({serial: fields[0], state: fields[1]});
		}
		return [for (device in devices) if (device.state == "device") device];
	}

	static function capture(command:String, arguments:Array<String>):CommandCapture {
		var process = new sys.io.Process(command, arguments);
		var stdout = process.stdout.readAll().toString(),
			stderr = process.stderr.readAll().toString(),
			status = process.exitCode();
		process.close();
		return {status: status, output: stdout + stderr};
	}

	/** How to install the pinned Android toolchain into the SDK the CLI uses (ANDROID_HOME, or .tools/android-sdk). */
	static function androidInstallHint(home:String):String
		return 'install the pinned toolchain with: cmake -P ${Path.join([home, "cmake", "haxeon-android-toolchain.cmake"])}';

	static function androidSdkDirectory(home:String):String {
		for (variable in ["ANDROID_HOME", "ANDROID_SDK_ROOT"]) {
			var configured = Sys.getEnv(variable);
			if (configured != null && configured != "")
				return FileSystem.absolutePath(configured);
		}
		var source = HaxeonSdk.source(home);
		return Path.join([source == null ? home : source, ".tools", "android-sdk"]);
	}

	static function configureAndroidEnvironment(home:String):Void {
		var sdk = androidSdkDirectory(home);
		Sys.putEnv("ANDROID_SDK_ROOT", sdk);
		Sys.putEnv("ANDROID_HOME", sdk);
		var ndk = androidVersion(home, "ndk");
		if (ndk != null)
			Sys.putEnv("ANDROID_NDK_ROOT", Path.join([sdk, "ndk", ndk]));
		var source = HaxeonSdk.source(home);
		if (source != null && Sys.getEnv("ANDROID_AVD_HOME") == null)
			Sys.putEnv("ANDROID_AVD_HOME", Path.join([source, ".tools", "android-avd"]));
	}

	static function androidVersion(home:String, tool:String):Null<String> {
		var versions = Path.join([home, "platforms", "android", "versions.txt"]);
		if (!FileSystem.exists(versions))
			return null;
		for (line in File.getContent(versions).split("\n")) {
			var fields = line.split("=");
			if (fields.length == 2 && fields[0] == tool)
				return StringTools.trim(fields[1]);
		}
		return null;
	}

	static function androidExecutable(home:String, executable:String):String
		return Path.join([androidSdkDirectory(home), "platform-tools", executable + executableSuffix()]);

	static function javaExecutable():String {
		var javaHome = Sys.getEnv("JAVA_HOME"),
			executable = "java" + (Sys.systemName() == "Windows" ? ".exe" : "");
		if (javaHome != null && javaHome.length > 0) {
			var candidate = Path.join([javaHome, "bin", executable]);
			if (FileSystem.exists(candidate))
				return candidate;
		}
		return "java";
	}

	static function parseBuildOptions(arguments:Array<String>):BuildOptions {
		var projectPath = ".",
			target:Null<String> = null,
			buildMode = "development",
			buildModeExplicit = false,
			output:Null<String> = null,
			device:Null<String> = null,
			defines = [],
			runtimeArguments = [],
			debugPort:Null<Int> = null,
			launchPlan:Null<String> = null,
			plan = false,
			explain = false,
			timings = false,
			verbosity = Verbosity.Minimal,
			diagnosticFormat = DiagnosticFormat.Full,
			color = "auto",
			quiet = false,
			compilerOnly = false,
			gradleInputs:Null<String> = null,
			standardLibrary = false,
			projectGiven = false,
			watch = false,
			restart = false,
			patchable = false,
			strictLive = false,
			jobs = 4,
			selfHosted = Sys.getEnv("HAXEON_SELF_HOSTED") == "1",
			profile = false,
			profileSources:Array<String> = null,
			profileOutput:Null<String> = null,
			profileStart = "launch",
			profileDuration = 0,
			profileMaxSize = ProfileCapture.DEFAULT_MAX_SIZE_MIB,
			profileWindow:Null<String> = null,
			profileMinCall:Null<Float> = null;
		var index = 0;
		while (index < arguments.length) {
			var argument = arguments[index++];
			if (argument == "--") {
				runtimeArguments = arguments.slice(index);
				break;
			}
			if (argument == "--plan")
				plan = true;
			else if (argument == "--explain")
				explain = true;
			else if (argument == "--timings")
				timings = true;
			else if (argument == "--quiet")
				quiet = true;
			else if (argument == "--compiler-only")
				compilerOnly = true;
			else if (argument == "--standard-library")
				standardLibrary = true;
			else if (argument == "--watch")
				watch = true;
			else if (argument == "--restart")
				restart = true;
			else if (argument == "--patchable")
				patchable = true;
			else if (argument == "--live")
				throw new UsageError('Option "--live" was removed: "haxeon run --watch" patches the running app by itself when its '
					+ 'entry class has the live entry points ("--restart" relaunches it instead), and '
					+ '"haxeon build --compiler-only --patchable" builds a module later builds publish patches of');
			else if (argument == "--strict-live")
				strictLive = true;
			else if (argument == "--self-hosted")
				selfHosted = true;
			else if (argument == "--profile")
				profile = true;
			else if (StringTools.startsWith(argument, "--profile=")) {
				profileSources = ProfileCapture.parseSources(argument.substr("--profile=".length));
				profile = true;
			} else if (argument == "--profile-output") {
				if (index >= arguments.length)
					throw new UsageError('Option "--profile-output" requires a value');
				profileOutput = arguments[index++];
				profile = true;
			} else if (argument == "-v" || argument == "--verbosity") {
				if (index >= arguments.length)
					throw new UsageError('Option "$argument" requires a value');
				verbosity = parseVerbosity(arguments[index++]);
			} else if (StringTools.startsWith(argument, "--verbosity="))
				verbosity = parseVerbosity(argument.substr("--verbosity=".length));
			else if (argument == "--color" || argument == "--diagnostic-format") {
				if (index >= arguments.length)
					throw new UsageError('Option "$argument" requires a value');
				if (argument == "--color")
					color = parseColor(arguments[index++]);
				else
					diagnosticFormat = parseDiagnosticFormat(arguments[index++]);
			} else if (StringTools.startsWith(argument, "--color="))
				color = parseColor(argument.substr("--color=".length));
			else if (StringTools.startsWith(argument, "--diagnostic-format="))
				diagnosticFormat = parseDiagnosticFormat(argument.substr("--diagnostic-format=".length));
			else if (argument == "--project" || argument == "--target" || argument == "--build-mode"
				|| argument == "--output" || argument == "--define"
				|| argument == "--device" || argument == "--jobs" || argument == "--gradle-inputs"
				|| argument == "--debug-port" || argument == "--launch-plan") {
				if (index >= arguments.length)
					throw new UsageError('Option "$argument" requires a value');
				var value = arguments[index++];
				switch argument {
					case "--project":
						projectPath = value;
						projectGiven = true;
					case "--target":
						target = value;
					case "--build-mode":
						buildMode = value;
						buildModeExplicit = true;
					case "--output":
						output = value;
					case "--define":
						defines.push(value);
					case "--device":
						device = value;
					case "--debug-port":
						debugPort = Std.parseInt(value);
						if (!~/^[0-9]+$/.match(value) || debugPort == null || debugPort < 1 || debugPort > 65535)
							throw new UsageError('Option "--debug-port" requires a port from 1 to 65535');
					case "--launch-plan":
						if (value.length == 0)
							throw new UsageError('Option "--launch-plan" requires a file path');
						launchPlan = value;
					case "--gradle-inputs":
						gradleInputs = resolvePath(value, Sys.getCwd());
					case "--jobs":
						var parsedJobs = Std.parseInt(value);
						if (parsedJobs == null || parsedJobs < 1)
							throw new UsageError('Option "--jobs" requires a positive integer');
						jobs = parsedJobs;
					case _:
				}
			} else if (StringTools.startsWith(argument, "--project=")) {
				projectPath = argument.substr("--project=".length);
				projectGiven = true;
			}
				else if (StringTools.startsWith(argument, "--target="))
				target = argument.substr("--target=".length);
			else if (StringTools.startsWith(argument, "--build-mode=")) {
				buildMode = argument.substr("--build-mode=".length);
				buildModeExplicit = true;
			} else if (StringTools.startsWith(argument, "--output="))
				output = argument.substr("--output=".length);
			else if (StringTools.startsWith(argument, "--device="))
				device = argument.substr("--device=".length);
			else if (StringTools.startsWith(argument, "--jobs=")) {
				var parsedJobs = Std.parseInt(argument.substr("--jobs=".length));
				if (parsedJobs == null || parsedJobs < 1)
					throw new UsageError('Option "--jobs" requires a positive integer');
				jobs = parsedJobs;
			} else if (StringTools.startsWith(argument, "--define="))
				defines.push(argument.substr("--define=".length));
			else if (StringTools.startsWith(argument, "--profile-start=")) {
				profile = true;
				profileStart = ProfileCapture.parseStart(argument.substr("--profile-start=".length));
			} else if (StringTools.startsWith(argument, "--profile-duration=")) {
				profile = true;
				profileDuration = nonNegativeInteger(argument.substr("--profile-duration=".length),
					"--profile-duration");
			} else if (StringTools.startsWith(argument, "--profile-max-size=")) {
				profile = true;
				profileMaxSize = nonNegativeInteger(argument.substr("--profile-max-size=".length),
					"--profile-max-size");
			} else if (StringTools.startsWith(argument, "--profile-window=")) {
				profile = true;
				profileWindow = ProfileCapture.parseWindow(argument.substr("--profile-window=".length));
			} else if (StringTools.startsWith(argument, "--profile-min-call=")) {
				profile = true;
				profileMinCall = ProfileCapture.parseMinCall(argument.substr("--profile-min-call=".length));
			} else if (StringTools.startsWith(argument, "--profile-output=")) {
				profileOutput = argument.substr("--profile-output=".length);
				profile = true;
			} else
				throw new UsageError('Unknown build option "$argument". See \'haxeon build --help\'.');
		}
		if (projectPath.length == 0)
			throw new UsageError('Option "--project" requires a value');
		if (buildMode != "release" && buildMode != "development")
			throw new UsageError('Unknown build mode "$buildMode". Valid: development, release');
		if (patchable && buildModeExplicit && buildMode != "development")
			throw new UsageError("--patchable requires development build mode");
		if (standardLibrary && projectGiven)
			throw new UsageError('Option "--standard-library" describes the standard library, not a project: it takes no "--project"');
		return {
			projectPath: projectPath,
			target: target,
			buildMode: buildMode,
			buildModeExplicit: buildModeExplicit,
			output: output,
			device: device,
			defines: defines,
			runtimeArguments: runtimeArguments,
			debugPort: debugPort,
			launchPlan: launchPlan,
			plan: plan,
			explain: explain,
			timings: timings,
			verbosity: verbosity,
			style: new ReportStyle(verbosity, diagnosticFormat, colorDiagnostics(color), invokedFrom),
			quiet: quiet,
			compilerOnly: compilerOnly,
			gradleInputs: gradleInputs,
			standardLibrary: standardLibrary,
			watch: watch,
			restart: restart,
			patchable: patchable,
			strictLive: strictLive,
			jobs: jobs,
			selfHosted: selfHosted,
			profile: profile,
			profileSources: profileSources == null ? ProfileCapture.defaultSources() : profileSources,
			profileControls: {
				start: profileStart,
				durationSeconds: profileDuration,
				maxSizeMiB: profileMaxSize,
				window: profileWindow,
				minCallMicros: profileMinCall
			},
			profileOutput: profileOutput
		};
	}

	/**
	 * The options a program the CLI made a project for builds with (a script, a Haxe command line's compilation): the defaults of
	 * `haxeon build`, with these set.
	 */
	static function programOptions(buildMode:String, verbosity:Verbosity, timings:Bool, quiet:Bool,
			runtimeArguments:Array<String>):BuildOptions
		return {
			projectPath: ".",
			target: null,
			buildMode: buildMode,
			buildModeExplicit: true,
			output: null,
			device: null,
			defines: [],
			runtimeArguments: runtimeArguments,
			debugPort: null,
			launchPlan: null,
			plan: false,
			explain: false,
			timings: timings,
			verbosity: verbosity,
			style: new ReportStyle(verbosity, DiagnosticFormat.Full, colorDiagnostics("auto"), invokedFrom),
			quiet: quiet,
			compilerOnly: false,
			gradleInputs: null,
			standardLibrary: false,
			watch: false,
			restart: false,
			patchable: false,
			strictLive: false,
			jobs: 4,
			selfHosted: Sys.getEnv("HAXEON_SELF_HOSTED") == "1",
			profile: false,
			profileSources: ProfileCapture.defaultSources(),
			profileControls: {
				start: "launch",
				durationSeconds: 0,
				maxSizeMiB: ProfileCapture.DEFAULT_MAX_SIZE_MIB,
				window: null,
				minCallMicros: null
			},
			profileOutput: null
		};

	static function parseVerbosity(value:String):Verbosity {
		var level = Verbosity.parse(value);
		if (level == null)
			throw new UsageError('Unknown verbosity "$value". Valid: ${Verbosity.NAMES.join(", ")}');
		return level;
	}

	static function parseColor(value:String):String {
		if (value != "auto" && value != "always" && value != "never")
			throw new UsageError('Unknown color mode "$value". Valid: auto, always, never');
		return value;
	}

	static function parseDiagnosticFormat(value:String):DiagnosticFormat {
		var format = DiagnosticFormat.parse(value);
		if (format == null)
			throw new UsageError('Unknown diagnostic format "$value". Valid: ${DiagnosticFormat.NAMES.join(", ")}');
		return format;
	}

	/**
	 * Whether diagnostics are coloured: `auto` colours them only for a terminal (the haxeon launcher says whether standard error
	 * is one, in HAXEON_STDERR_TERMINAL) and not when NO_COLOR is set or TERM is dumb.
	 */
	static function colorDiagnostics(mode:String):Bool {
		if (mode != "auto")
			return mode == "always";
		var noColor = Sys.getEnv("NO_COLOR");
		return (noColor == null || noColor == "") && Sys.getEnv("TERM") != "dumb"
			&& Sys.getEnv("HAXEON_STDERR_TERMINAL") == "1";
	}

	static function parsePackageOptions(arguments:Array<String>, allowLocked:Bool, command:String):PackageOptions {
		var projectPath = ".", locked = false, index = 0;
		while (index < arguments.length) {
			var argument = arguments[index++];
			if (argument == "--locked") {
				if (!allowLocked)
					throw new UsageError('Unknown $command option "--locked"');
				locked = true;
			} else if (argument == "--project") {
				if (index >= arguments.length)
					throw new UsageError('Option "--project" requires a value');
				projectPath = arguments[index++];
			} else if (StringTools.startsWith(argument, "--project="))
				projectPath = argument.substr("--project=".length);
			else
				throw new UsageError('Unknown $command option "$argument"');
		}
		return {projectPath: projectPath, locked: locked};
	}

	static function parseAddOptions(arguments:Array<String>):AddOptions {
		var projectPath = ".",
			name:Null<String> = null,
			git:Null<String> = null,
			rev:Null<String> = null,
			registry:Null<String> = null,
			version:Null<String> = null,
			index = 0;
		while (index < arguments.length) {
			var argument = arguments[index++];
			if (argument == "--git" || argument == "--rev" || argument == "--name" || argument == "--project"
				|| argument == "--registry" || argument == "--version") {
				if (index >= arguments.length)
					throw new UsageError('Option "$argument" requires a value');
				var value = arguments[index++];
				switch argument {
					case "--git":
						git = value;
					case "--rev":
						rev = value;
					case "--name":
						name = value;
					case "--project":
						projectPath = value;
					case "--registry":
						registry = value;
					case "--version":
						version = value;
					case _:
				}
			} else if (StringTools.startsWith(argument, "--registry="))
				registry = argument.substr("--registry=".length);
			else if (StringTools.startsWith(argument, "--version="))
				version = argument.substr("--version=".length);
			else if (StringTools.startsWith(argument, "--git="))
				git = argument.substr("--git=".length);
			else if (StringTools.startsWith(argument, "--rev="))
				rev = argument.substr("--rev=".length);
			else if (StringTools.startsWith(argument, "--name="))
				name = argument.substr("--name=".length);
			else if (StringTools.startsWith(argument, "--project="))
				projectPath = argument.substr("--project=".length);
			else if (StringTools.startsWith(argument, "--"))
				throw new UsageError('Unknown add option "$argument"');
			else if (name == null)
				name = argument;
			else
				throw new UsageError('Unexpected add argument "$argument"');
		}
		if (git == null) {
			if (rev != null)
				throw new UsageError('Option "--rev" needs "--git"');
			if (name == null || name.length == 0)
				throw new UsageError('A registry dependency needs a package name: haxeon add NAME');
			if (registry != null && registry.length == 0 || version != null && version.length == 0)
				throw new UsageError('Options "--registry" and "--version" need a non-empty value');
		} else {
			if (registry != null || version != null)
				throw new UsageError('Options "--registry" and "--version" are for registry dependencies, not "--git"');
			if (git.length == 0)
				throw new UsageError('Option "--git" requires a non-empty URL');
			if (rev == null || rev.length == 0)
				throw new UsageError('Option "--rev" requires a non-empty ref');
		}
		return {
			projectPath: projectPath,
			name: name,
			git: git,
			rev: rev,
			registry: registry,
			version: version
		};
	}

	static function parsePublishOptions(arguments:Array<String>):PublishOptions {
		var projectPath = ".", registry:Null<String> = null, version:Null<String> = null, index = 0;
		while (index < arguments.length) {
			var argument = arguments[index++];
			if (argument == "--registry" || argument == "--version" || argument == "--project") {
				if (index >= arguments.length)
					throw new UsageError('Option "$argument" requires a value');
				var value = arguments[index++];
				switch argument {
					case "--registry":
						registry = value;
					case "--version":
						version = value;
					case "--project":
						projectPath = value;
					case _:
				}
			} else if (StringTools.startsWith(argument, "--registry="))
				registry = argument.substr("--registry=".length);
			else if (StringTools.startsWith(argument, "--version="))
				version = argument.substr("--version=".length);
			else if (StringTools.startsWith(argument, "--project="))
				projectPath = argument.substr("--project=".length);
			else
				throw new UsageError('Unknown publish option "$argument"');
		}
		if (registry == null || registry.length == 0)
			throw new UsageError('Option "--registry" requires a non-empty registry name');
		if (version == null || version.length == 0)
			throw new UsageError('Option "--version" requires an exact package version');
		return {projectPath: projectPath, registry: registry, version: version};
	}

	static function discoverProject(manifestPath:String, ?target:Target):ResolvedProject
		return ProjectDiscovery.resolve(manifestPath, target);

	static function resolveProject(manifestPath:String, lockfile:Null<PackageLockfile>, locked:Bool,
			?target:Target):ResolvedProject {
		return new PackageResolver(ProjectDiscovery.sourceAcquirer()).resolve(manifestPath, lockfile, locked, target,
			null, locked);
	}

	/** Identifies the lockfile's current state without reading it. */
	static function lockfileStamp(manifestPath:String):String {
		var path = lockfilePath(manifestPath);
		if (!FileSystem.exists(path))
			return "absent";
		var stat = FileSystem.stat(path);
		return '${stat.mtime.getTime()}:${stat.size}';
	}

	static function lockfilePath(manifestPath:String):String
		return ProjectDiscovery.lockfilePath(manifestPath);

	static function inferPackageName(url:String):String {
		var value = url;
		while (StringTools.endsWith(value, "/"))
			value = value.substr(0, value.length - 1);
		var slash = value.lastIndexOf("/");
		value = slash < 0 ? value : value.substr(slash + 1);
		return StringTools.endsWith(value, ".git") ? value.substr(0, value.length - 4) : value;
	}

	static function printTree(packageValue:ResolvedPackage, project:ResolvedProject, prefix:String,
			active:Map<String, Bool>):Void {
		Sys.println('$prefix${packageValue.name} [${projectPackageSource(packageValue)}]');
		if (active.exists(packageValue.name))
			return;
		active.set(packageValue.name, true);
		for (dependency in packageValue.dependencies) {
			var child = project.packages.get(dependency);
			if (child != null)
				printTree(child, project, prefix + "  ", active);
		}
		active.remove(packageValue.name);
	}

	static function projectPackageSource(packageValue:ResolvedPackage):String
		return PackageSourceTools.describe(packageValue.source);

	static function packagePath(current:ResolvedPackage, target:String, project:ResolvedProject,
			active:Map<String, Bool>):Null<Array<String>> {
		if (current.name == target)
			return [current.name];
		if (active.exists(current.name))
			return null;
		active.set(current.name, true);
		for (dependency in current.dependencies) {
			var child = project.packages.get(dependency);
			if (child != null) {
				var path = packagePath(child, target, project, active);
				if (path != null) {
					active.remove(current.name);
					return [current.name].concat(path);
				}
			}
		}
		active.remove(current.name);
		return null;
	}

	static function runtimeLibraryPath(home:String, extraDirectories:Array<String>):{name:String, value:String} {
		var directories = HashLinkPath.libraryPath(home).concat(extraDirectories);
		var variable = switch Sys.systemName() {
			case "Windows": "PATH";
			case "Mac": "DYLD_LIBRARY_PATH";
			case _: "LD_LIBRARY_PATH";
		};
		var existing = Sys.getEnv(variable);
		if (existing != null && existing.length > 0)
			directories.push(existing);
		return {name: variable, value: directories.join(Sys.systemName() == "Windows" ? ";" : ":")};
	}

	/**
		A variable's value that stays valid after the variable is set again. On HashLink for Windows, Sys.getEnv returns a
		String over the C runtime's own copy of the value, which Sys.putEnv frees.
	**/
	static function environmentCopy(name:String):Null<String> {
		var value = Sys.getEnv(name);
		return value == null ? null : haxe.io.Bytes.ofString(value).toString();
	}

	/** Haxeon's home: the SDK the launcher runs from (`HaxeonSdk.current`). */
	static function haxeonHome():String {
		var home = HaxeonSdk.current();
		if (home == null)
			throw new InternalError("HAXEON_SDK is not set; run the CLI through its launcher (bin/haxeon, scripts/haxeon in a checkout)");
		return home;
	}

	/** The manifest `--project` names: the file, or the haxeon.toml or haxeon.json of the directory (PackageManifest.find). */
	static function projectManifest(projectPath:String):String {
		var path = resolvePath(projectPath, Sys.getCwd());
		return FileSystem.isDirectory(path) ? PackageManifest.pathIn(path) : path;
	}

	static function resolvePath(path:String, base:String):String {
		return Path.normalize(Path.isAbsolute(path) ? path : Path.join([base, path]));
	}

	static function ensureDirectory(path:String):Void {
		if (path == null || path == "" || path == "." || FileSystem.exists(path))
			return;
		var parent = Path.directory(path);
		if (parent != path && parent != "")
			ensureDirectory(parent);
		if (!FileSystem.exists(path))
			FileSystem.createDirectory(path);
	}

	static function nonNegativeInteger(value:String, option:String):Int {
		var parsed = Std.parseInt(value);
		if (parsed == null || parsed < 0 || Std.string(parsed) != StringTools.trim(value))
			throw new UsageError('Option "$option" takes a whole number of at least 0');
		return parsed;
	}

	static function executableSuffix():String
		return Sys.systemName() == "Windows" ? ".exe" : "";

	/** Resolves help before dispatch, without consuming options forwarded to a script or tool. */
	static function requestedHelp(command:String, arguments:Array<String>):Null<String> {
		if (arguments.length > 1 && (arguments[1] == "--help" || arguments[1] == "-h")) {
			var subcommand = CliHelp.command(command + " " + arguments[0]);
			if (subcommand != null)
				return subcommand;
		}
		var help = CliHelp.command(command);
		if (help == null)
			return null;
		var forwards = ["lsp", "ffi", "dev", "heap", "lint", "help"].indexOf(command) >= 0
			|| (command == "run" && arguments.length > 0 && ScriptRun.isScript(arguments[0]));
		for (argument in (forwards ? arguments.slice(0, 1) : arguments)) {
			if (argument == "--")
				break;
			if (argument == "--help" || argument == "-h")
				return help;
		}
		return null;
	}

	/** One line for a mistyped command, with the closest command when there is one. */
	static function unknownCommand(name:String):Void {
		var suggestion = CliHelp.suggestion(name);
		Sys.stderr().writeString('haxeon: unknown command "$name"'
			+ (suggestion == null ? "." : '; did you mean "$suggestion"?') + " See 'haxeon --help'.\n");
	}

	static function commandHelp(name:String):Int {
		var help = CliHelp.command(name);
		if (help == null) {
			unknownCommand(name);
			return 2;
		}
		Sys.println(help);
		return 0;
	}

	/** `haxeon version`: this CLI's version, the checkout's commit, which names the compiler, and the VM's version. */
	static function version():Int {
		var home = haxeonHome(),
			source = HaxeonSdk.source(home),
			released = HaxeonSdk.field(home, "commit"),
			commit = source == null ? {status: released == null ? 1 : 0,
				output: released == null ? "" : released} : ProcessRunner.capture("git",
				["-C", source, "rev-parse", "--short=12", "HEAD"]),
			hashlink = ProcessRunner.capture(Path.join([HashLinkPath.directory(home), "hl" + executableSuffix()]),
				["--version"]);
		Sys.println('haxeon ${project.PackageCompatibility.CURRENT_HAXEON} (compiler '
			+ (commit.status == 0 ? StringTools.trim(commit.output) : "unknown") + ", HashLink "
			+ (hashlink.status == 0 ? StringTools.trim(hashlink.output) : "unknown") + ")");
		return 0;
	}

	static function usage(status:Int = 0):Int {
		Sys.println(CliHelp.overview());
		return status;
	}
}
