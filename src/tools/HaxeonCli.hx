package tools;

import haxe.Json;
import haxe.io.Path;
import build.HaxeonProjectBuild;
import build.HaxeonNativePackageBuild;
import build.Target;
import build.NativeTargetSupport;
import build.execution.ProcessRunner;
import project.PackageLockfile;
import project.PackageResolver;
import project.PackageSourceTools;
import project.ProjectSourceAcquirer;
import project.ResolvedPackage;
import project.ResolvedProject;
import project.SourceCache;
import project.RegistryPublisher;
import sys.FileSystem;
import sys.io.File;
import compiler.formatter.Formatter;
import compiler.formatter.FormatConfig.FormatConfigTools;

private typedef ProjectConfig = {
	final entry:String;
	final sources:Array<String>;
	final sourceRoots:Array<String>;
	final target:String;
	final defines:Array<String>;
	final outputDir:String;
	final androidApplicationId:String;
	final androidAppLabel:String;
}

private typedef BuildOptions = {
	final projectPath:String;
	final target:Null<String>;
	final output:Null<String>;
	final device:Null<String>;
	final defines:Array<String>;
	final runtimeArguments:Array<String>;
	final plan:Bool;
	final explain:Bool;
	final timings:Bool;
	final compilerOnly:Bool;
	final jobs:Int;
	final selfHosted:Bool;
	final profile:Bool;
	final profileOutput:Null<String>;
}

private typedef FormatOptions = {
	final check:Bool;
	final stdin:Bool;
	final lineWidth:Int;
	final indentWidth:Int;
	final useTabs:Bool;
	final paths:Array<String>;
}

private typedef PackageOptions = {
	final projectPath:String;
	final locked:Bool;
}

private typedef AddOptions = {
	final projectPath:String;
	final name:Null<String>;
	final git:String;
	final rev:String;
}

private typedef PublishOptions = {
	final projectPath:String;
	final registry:String;
	final version:String;
}

private typedef CommandCapture = {
	final status:Int;
	final output:String;
}

/** Project-facing build and launch commands for Haxeon applications. */
class HaxeonCli {
	static final CONFIG_FILE = "haxeon.json";

	public static function main():Void {
		var arguments = Sys.args();
		if (arguments.length == 0) {
			usage();
			Sys.exit(2);
		}

		var command = arguments.shift();
		try {
			var status = switch command {
				case "init": init(arguments);
				case "add": add(arguments);
				case "install": install(arguments);
				case "update": update(arguments);
				case "tree": tree(arguments);
				case "why": why(arguments);
				case "publish": publish(arguments);
				case "package": packageCommand(arguments);
				case "doctor": doctor(arguments);
				case "platforms": platforms(arguments);
				case "devices": devices(arguments);
				case "fmt": fmt(arguments);
				case "build": build(arguments, false);
				case "run": build(arguments, true);
				case "heap": HeapInspector.run(arguments);
				case "help", "--help", "-h": usage();
				case _:
					Sys.stderr().writeString('Unknown command: $command\n');
					usage(2);
			};
			Sys.exit(status);
		} catch (error:Dynamic) {
			Sys.stderr().writeString("haxeon: " + Std.string(error) + "\n");
			Sys.exit(1);
		}
	}

	static function init(arguments:Array<String>):Int {
		var entry = "Main", target = "host";
		var index = 0;
		while (index < arguments.length) {
			var argument = arguments[index++];
			if (argument == "--entry") {
				if (index >= arguments.length)
					throw 'Option "--entry" requires a value';
				entry = arguments[index++];
			} else if (argument == "--target") {
				if (index >= arguments.length)
					throw 'Option "--target" requires a value';
				target = arguments[index++];
			} else if (StringTools.startsWith(argument, "--entry="))
				entry = argument.substr("--entry=".length);
			else if (StringTools.startsWith(argument, "--target="))
				target = argument.substr("--target=".length);
			else
				throw 'Unknown init option "$argument"';
		}
		if (entry.length == 0)
			throw 'Option "--entry" requires a value';
		try {
			Target.parse(target);
		} catch (error:Dynamic) {
			throw 'Unsupported init target "$target": ${Std.string(error)}';
		}

		var projectDirectory = Sys.getCwd(),
			configPath = Path.join([projectDirectory, CONFIG_FILE]);
		if (FileSystem.exists(configPath))
			throw '$CONFIG_FILE already exists in $projectDirectory';

		var sourcePath = "src/" + entry.split(".").join("/") + ".hx";
		var absoluteSource = resolvePath(sourcePath, projectDirectory);
		ensureDirectory(Path.directory(absoluteSource));
		if (!FileSystem.exists(absoluteSource)) {
			var entryParts = entry.split("."),
				packageName = entryParts.length > 1 ? entryParts.slice(0, entryParts.length - 1).join(".") : null;
			var source = packageName == null ? "" : 'package $packageName;\n\n';
			var mainSource = target == "android" ? "function main():Void {}\n" : "function main():Int return 0;\n";
			File.saveContent(absoluteSource, source + mainSource);
		}

		var config:Dynamic = {
			version: 1,
			entry: entry,
			sources: [sourcePath],
			sourceRoots: ["src"],
			target: target,
			defines: [],
			outputDir: "build",
		};
		var normalizedProjectDirectory = Path.normalize(FileSystem.fullPath(projectDirectory)),
			packageName = Path.withoutDirectory(normalizedProjectDirectory);
		if (packageName.length == 0)
			throw 'Could not derive a package name from project directory $normalizedProjectDirectory';
		Reflect.setField(config, "package", {name: packageName});
		if (target == "android")
			Reflect.setField(config, "android", {applicationId: "org.haxeon.android", label: "Haxeon"});
		File.saveContent(configPath, Json.stringify(config, null, "\t") + "\n");
		Sys.println('Created $CONFIG_FILE and $sourcePath');
		return 0;
	}

	static function fmt(arguments:Array<String>):Int {
		var check = false, stdin = false, lineWidth = 120, indentWidth = 2, useTabs = false, paths:Array<String> = [], index = 0;
		while (index < arguments.length) {
			var argument = arguments[index++];
			if (argument == "--check")
				check = true;
			else if (argument == "--stdin")
				stdin = true;
			else if (argument == "--use-tabs")
				useTabs = true;
			else if (argument == "--spaces" || argument == "--insert-spaces")
				useTabs = false;
			else if (argument == "--line-width" || argument == "--tab-size") {
				if (index >= arguments.length)
					throw 'Option "$argument" requires a positive integer';
				var value = Std.parseInt(arguments[index++]);
				if (value == null || value < 1)
					throw 'Option "$argument" requires a positive integer';
				if (argument == "--line-width")
					lineWidth = value;
				else
					indentWidth = value;
			} else if (StringTools.startsWith(argument, "--line-width=")) {
				lineWidth = parsePositiveFormatOption(argument.substr("--line-width=".length), "--line-width");
			} else if (StringTools.startsWith(argument, "--tab-size=")) {
				indentWidth = parsePositiveFormatOption(argument.substr("--tab-size=".length), "--tab-size");
			} else if (StringTools.startsWith(argument, "-"))
				throw 'Unknown fmt option "$argument"';
			else
				paths.push(argument);
		}
		if (stdin && paths.length > 0)
			throw 'haxeon fmt --stdin cannot be combined with file paths';
		if (!stdin && paths.length == 0)
			throw 'haxeon fmt requires a file path or --stdin';
		var options:FormatOptions = {
			check: check,
			stdin: stdin,
			lineWidth: lineWidth,
			indentWidth: indentWidth,
			useTabs: useTabs,
			paths: paths
		};
		var config = FormatConfigTools.defaults(options.indentWidth, !options.useTabs);
		config.lineWidth = options.lineWidth;
		if (options.stdin) {
			var source = Sys.stdin().readAll().toString(),
				formatted = Formatter.format(source, config);
			if (formatted == null)
				throw "cannot format malformed source from stdin";
			if (options.check)
				return formatted == source ? 0 : 1;
			Sys.print(formatted);
			return 0;
		}
		var status = 0;
		for (path in options.paths) {
			if (!FileSystem.exists(path))
				throw 'Source file not found: $path';
			var source = File.getContent(path),
				formatted = Formatter.format(source, config);
			if (formatted == null)
				throw 'Cannot format malformed source: $path';
			if (formatted == source)
				continue;
			if (options.check) {
				Sys.println('Would reformat $path');
				status = 1;
			} else
				File.saveContent(path, formatted);
		}
		return status;
	}

	static function parsePositiveFormatOption(value:String, option:String):Int {
		var parsed = Std.parseInt(value);
		if (parsed == null || parsed < 1)
			throw 'Option "$option" requires a positive integer';
		return parsed;
	}

	static function add(arguments:Array<String>):Int {
		var options = parseAddOptions(arguments),
			manifestPath = resolvePath(options.projectPath, Sys.getCwd());
		if (!FileSystem.exists(manifestPath))
			throw 'Project file not found: $manifestPath';
		var name = options.name == null ? inferPackageName(options.git) : options.name;
		if (name == null || name.length == 0)
			throw 'Git dependencies require a package name (pass it as the final argument or with --name)';
		var raw:Dynamic;
		try {
			raw = Json.parse(File.getContent(manifestPath));
		} catch (error:Dynamic) {
			throw 'Could not parse $manifestPath: ${Std.string(error)}';
		}
		if (raw == null || !Reflect.isObject(raw) || Std.isOfType(raw, Array))
			throw '$manifestPath must contain a JSON object';
		var dependencies:Dynamic = Reflect.field(raw, "dependencies");
		if (dependencies == null) {
			dependencies = {};
			Reflect.setField(raw, "dependencies", dependencies);
		}
		if (!Reflect.isObject(dependencies) || Std.isOfType(dependencies, Array))
			throw '$manifestPath "dependencies" must be an object';
		if (Reflect.hasField(dependencies, name))
			throw 'Dependency "$name" is already declared in $manifestPath';
		Reflect.setField(dependencies, name, {git: options.git, rev: options.rev});
		File.saveContent(manifestPath, Json.stringify(raw, null, "\t") + "\n");
		Sys.println('Added Git dependency ${name}@${options.rev}');
		return 0;
	}

	static function install(arguments:Array<String>):Int {
		var options = parsePackageOptions(arguments, true, "install"),
			manifestPath = resolvePath(options.projectPath, Sys.getCwd()),
			lockPath = lockfilePath(manifestPath),
			lockfile = FileSystem.exists(lockPath) ? PackageLockfile.parse(lockPath, File.getContent(lockPath)) : null;
		if (options.locked && lockfile == null)
			throw 'haxeon.lock is required for "haxeon install --locked"';
		var project = resolveProject(manifestPath, lockfile, options.locked);
		if (!options.locked)
			project.lockfile.save(lockPath);
		Sys.println('${options.locked ? "Validated" : "Installed"} ${project.packages.packages.length} packages');
		return 0;
	}

	static function update(arguments:Array<String>):Int {
		var options = parsePackageOptions(arguments, false, "update"),
			manifestPath = resolvePath(options.projectPath, Sys.getCwd()),
			project = resolveProject(manifestPath, null, false);
		project.lockfile.save(lockfilePath(manifestPath));
		Sys.println('Updated ${project.packages.packages.length} packages');
		return 0;
	}

	static function publish(arguments:Array<String>):Int {
		var options = parsePublishOptions(arguments),
			manifestPath = resolvePath(options.projectPath, Sys.getCwd()),
			checksum = RegistryPublisher.publish(manifestPath, options.registry, options.version, SourceCache.registryRoot());
		Sys.println('Published ${options.version} from $manifestPath to ${options.registry} (checksum $checksum)');
		return 0;
	}

	static function packageCommand(arguments:Array<String>):Int {
		if (arguments.length == 0 || arguments[0] != "check")
			throw 'Usage: haxeon package check [--project PATH]';
		var options = parsePackageOptions(arguments.slice(1), false, "package check"),
			manifestPath = resolvePath(options.projectPath, Sys.getCwd()),
			project = discoverProject(manifestPath),
			target = Target.parse(project.manifest.target);
		NativeTargetSupport.validate(project, target);
		Sys.println('Package graph for ${project.rootPackage.name} [${target.toString()}]');
		for (resolvedPackage in project.packages.packages) {
			var native = resolvedPackage.manifest.native == null ? "none" : resolvedPackage.manifest.native.cmake != null ? "cmake" : "sources";
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
			manifestPath = resolvePath(options.projectPath, Sys.getCwd()),
			project = discoverProject(manifestPath);
		printTree(project.rootPackage, project, "", new Map());
		return 0;
	}

	static function why(arguments:Array<String>):Int {
		var projectPath = CONFIG_FILE, packageName:Null<String> = null, index = 0;
		while (index < arguments.length) {
			var argument = arguments[index++];
			if (argument == "--project") {
				if (index >= arguments.length)
					throw 'Option "--project" requires a value';
				projectPath = arguments[index++];
			} else if (StringTools.startsWith(argument, "--project="))
				projectPath = argument.substr("--project=".length);
			else if (StringTools.startsWith(argument, "--"))
				throw 'Unknown why option "$argument"';
			else if (packageName == null)
				packageName = argument;
			else
				throw 'Unexpected why argument "$argument"';
		}
		if (packageName == null || packageName.length == 0)
			throw 'Usage: haxeon why <package> [--project PATH]';
		var project = discoverProject(resolvePath(projectPath, Sys.getCwd())),
			path = packagePath(project.rootPackage, packageName, project, new Map());
		if (path == null)
			throw 'Package "$packageName" is not reachable from ${project.rootPackage.name}';
		Sys.println(path.join(" -> "));
		return 0;
	}

	static function doctor(arguments:Array<String>):Int {
		if (arguments.length != 0)
			throw 'Unexpected doctor argument "${arguments[0]}"';
		var home = haxeonHome(), suffix = executableSuffix();
		var haxePath = Path.join([home, ".tools", "haxe", "haxe" + suffix]);
		var hashlinkPath = Path.join([home, ".tools", "hashlink", "hl" + suffix]);
		var nativeRuntimePath = Path.join([home, "out", "haxeon_runtime.hdll"]);
		var compilerPath = Path.join([home, "bootstrap", "compiler.hl"]);
		var androidSdk = Path.join([home, ".tools", "android-sdk"]);
		var missingRequired = false;

		missingRequired = reportPath("pinned Haxe compiler", haxePath, true) || missingRequired;
		missingRequired = reportPath("HashLink runtime", hashlinkPath, true) || missingRequired;
		missingRequired = reportPath("Haxeon runtime library", nativeRuntimePath, true) || missingRequired;
		reportPath("self-hosted compiler", compilerPath, false);
		reportPath("Android SDK", androidSdk, false);
		reportPath("Android NDK 30.0.16248370", Path.join([androidSdk, "ndk", "30.0.16248370"]), false);
		reportPath("Android platform tools (adb)", androidExecutable(home, "adb"), false);
		Sys.println("CMake and Ninja are only needed to rebuild the native runtime.");
		if (missingRequired)
			Sys.stderr().writeString("Run the repository's setup/bootstrap tools to install missing dependencies.\n");
		return missingRequired ? 1 : 0;
	}

	static function reportPath(label:String, path:String, required:Bool):Bool {
		var exists = FileSystem.exists(path);
		Sys.println('${exists ? "ok" : (required ? "missing" : "not built")}: $label ($path)');
		return required && !exists;
	}

	static function platforms(arguments:Array<String>):Int {
		if (arguments.length != 0)
			throw 'Unexpected platforms argument "${arguments[0]}"';
		Sys.println("Available through this CLI:");
		Sys.println('  host     build and run HashLink on the current host (${Sys.systemName()})');
		Sys.println("  wasm32   build experimental WebAssembly output; run is not wired up");
		Sys.println("  android  build APKs and install/launch on a connected device (Android SDK required)");
		Sys.println("Use \"haxeon devices\" to list connected Android devices.");
		return 0;
	}

	static function devices(arguments:Array<String>):Int {
		if (arguments.length != 0)
			throw 'Unexpected devices argument "${arguments[0]}"';
		var home = haxeonHome();
		configureAndroidEnvironment(home);
		var adb = androidExecutable(home, "adb");
		if (!FileSystem.exists(adb))
			throw 'Android adb is missing at $adb (install the Android platform tools under .tools/android-sdk)';
		var result = capture(adb, ["devices", "-l"]);
		Sys.print(result.output);
		return result.status;
	}

	static function build(arguments:Array<String>, launch:Bool):Int {
		var options = parseBuildOptions(arguments),
			projectConfigPath = resolvePath(options.projectPath, Sys.getCwd());
		if (!FileSystem.exists(projectConfigPath))
			throw 'Project file not found: $projectConfigPath (run "haxeon init" to create one)';
		var projectDirectory = Path.directory(projectConfigPath);
		if (projectDirectory == "")
			projectDirectory = Sys.getCwd();
		var requestedTarget:Null<Target> = options.target == null ? null : Target.parse(options.target),
			resolveStarted = Sys.time() * 1000.0,
			project = discoverProject(projectConfigPath, requestedTarget),
			resolutionMs = Sys.time() * 1000.0 - resolveStarted,
			target = options.target == null ? project.manifest.target : options.target,
			targetInfo = requestedTarget == null ? Target.parse(target) : requestedTarget;
		if (launch && targetInfo.isWasm())
			throw 'The "$target" target can be built, but this CLI has no runner for it yet.';
		if (options.plan && launch)
			throw 'Option "--plan" is only valid with "haxeon build"';
		if (options.explain && launch)
			throw 'Option "--explain" is only valid with "haxeon build"';
		if (options.compilerOnly && launch)
			throw 'Option "--compiler-only" is only valid with "haxeon build"';
		if (!launch && options.device != null)
			throw 'Option "--device" is only valid with "haxeon run --target android"';
		if (!targetInfo.isAndroid() && options.device != null)
			throw 'Option "--device" requires "--target android"';
		if ((options.plan || options.explain || options.timings)
			&& !(targetInfo.equals(Target.detectHost()) && Target.parse(project.manifest.target).equals(Target.detectHost())))
			throw 'Plan, explanation, and timing output are currently available for structured host builds only';
		if (options.selfHosted
			&& !(targetInfo.equals(Target.detectHost()) && Target.parse(project.manifest.target).equals(Target.detectHost())))
			throw 'The self-hosted compiler is currently available for structured host builds only';
		if (options.profile
			&& (!launch || !(targetInfo.equals(Target.detectHost()) && Target.parse(project.manifest.target).equals(Target.detectHost()))))
			throw 'Profiling is currently available for "haxeon run" host builds only';

		var home = haxeonHome();
		NativeTargetSupport.validate(project, targetInfo);
		if (targetInfo.equals(Target.detectHost()) && Target.parse(project.manifest.target).equals(Target.detectHost())) {
			var output = options.output == null ? resolvePath(Path.join([project.manifest.outputDir, "host", "main.hl"]),
				project.root) : resolvePath(options.output, project.root);
			var buildStatus = HaxeonProjectBuild.build(project, home, output, options.defines, options.jobs, options.plan, options.explain, options.timings,
				resolutionMs, options.selfHosted, options.compilerOnly);
			if (buildStatus != 0 || !launch)
				return buildStatus;
			var hashlink = Path.join([home, ".tools", "hashlink", "hl" + executableSuffix()]);
			if (!FileSystem.exists(hashlink))
				throw 'HashLink is missing: $hashlink (run scripts/bootstrap-tools.sh)';
			var nativeDirectories = [
				for (resolvedPackage in project.packages.packages)
					if (resolvedPackage.nativeSources.length > 0
						|| (resolvedPackage.manifest.native != null
							&& resolvedPackage.manifest.native.cmake != null))
						Path.join([project.root, project.manifest.outputDir, "host", "native", resolvedPackage.name])
			];
			configureRuntimeLibraryPath(home, nativeDirectories);
			if (options.profile) {
				var capture = options.profileOutput == null ? defaultProfileCapture(output) : resolvePath(options.profileOutput, project.root);
				return runProfiled(home, output, options.runtimeArguments, project.root, capture);
			}
			Sys.println('Launching $output');
			return ProcessRunner.run(hashlink, [output].concat(options.runtimeArguments), project.root, new Map());
		}
		if (options.plan)
			throw 'Plan output is currently available for host builds only';
		for (resolvedPackage in project.packages.packages)
			if (resolvedPackage.nativeSources.length > 0 && !targetInfo.isAndroid())
				throw 'Native C package "${resolvedPackage.name}" requires target "host" or an Android NDK provider; target "$target" is not supported yet';
		var config = loadConfig(projectConfigPath);
		if (targetInfo.isAndroid()) {
			configureAndroidEnvironment(home);
			var nativeStatus = HaxeonNativePackageBuild.build(project, home, targetInfo, options.jobs, false);
			if (nativeStatus != 0)
				return nativeStatus;
			var androidOutput = options.output == null ? defaultOutput(config, projectDirectory, "android") : resolvePath(options.output, projectDirectory);
			var status = buildAndroid(home, projectConfigPath, config, androidOutput, HaxeonNativePackageBuild.nativeRoot(project, targetInfo));
			if (status != 0 || !launch)
				return status;
			return installAndLaunchAndroid(home, androidOutput, config.androidApplicationId, options.device);
		}

		var output = options.output == null ? defaultOutput(config, projectDirectory, target) : resolvePath(options.output, projectDirectory);
		ensureDirectory(Path.directory(output));
		var compiler = Path.join([home, ".tools", "haxe", "haxe" + executableSuffix()]);
		if (!FileSystem.exists(compiler))
			throw 'Pinned Haxe is missing: $compiler (run scripts/bootstrap-tools.sh)';

		var compilerArguments = [
			"-cp",
			Path.join([home, "src"]),
			"--run",
			"compiler.tools.HaxeonCompiler",
			"--target=" + (target == "host" ? "hl" : "wasm32"),
			"--output=" + output,
			"--entry=" + config.entry
		];
		for (root in config.sourceRoots)
			compilerArguments.push("--root=" + resolvePath(root, projectDirectory));
		for (define in config.defines.concat(options.defines))
			compilerArguments.push("--define=" + define);
		for (source in config.sources) {
			var absoluteSource = resolvePath(source, projectDirectory);
			if (!FileSystem.exists(absoluteSource))
				throw 'Source file not found: $absoluteSource';
			compilerArguments.push(absoluteSource);
		}

		var compileStatus:Int;
		try {
			// CompilerDriver resolves Haxeon's bundled stdlib relative to the repo.
			compileStatus = ProcessRunner.run(compiler, compilerArguments, home, new Map());
		} catch (error:Dynamic) {
			throw error;
		}
		if (compileStatus != 0)
			return compileStatus;
		if (!launch) {
			Sys.println('Built $target -> $output');
			return 0;
		}

		var hashlink = Path.join([home, ".tools", "hashlink", "hl" + executableSuffix()]);
		if (!FileSystem.exists(hashlink))
			throw 'HashLink is missing: $hashlink (run scripts/bootstrap-tools.sh)';
		configureRuntimeLibraryPath(home);
		Sys.println('Launching $output');
		return ProcessRunner.run(hashlink, [output].concat(options.runtimeArguments), projectDirectory, new Map());
	}

	static function defaultProfileCapture(output:String):String {
		var directory = Path.join([Path.directory(output), "profile", 'profile-${Std.int(Date.now().getTime())}']);
		ensureDirectory(directory);
		return Path.join([directory, "profile.hlpc"]);
	}

	static function allocateDiagnosticsPort():Int {
		for (_ in 0...20) {
			var port = 20000 + Std.random(40000),
				socket = new sys.net.Socket();
			try {
				socket.bind(new sys.net.Host("127.0.0.1"), port);
				socket.close();
				return port;
			} catch (_:Dynamic) {
				socket.close();
			}
		}
		throw "Could not find a free diagnostics port for profiling";
	}

	static function pumpProcessOutput(input:haxe.io.Input, output:haxe.io.Output, done:sys.thread.Lock):Void {
		sys.thread.Thread.create(function() {
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

	static function runProfiled(home:String, output:String, runtimeArguments:Array<String>, projectDirectory:String, capture:String):Int {
		var suffix = executableSuffix(),
			runtime = Path.join([home, ".tools", "hashlink", "hl" + suffix]),
			profiler = Path.join([home, ".tools", "hashlink", "hlprof-live" + suffix]);
		if (!FileSystem.exists(runtime))
			throw 'HashLink is missing: $runtime (run scripts/bootstrap-tools.sh)';
		if (!FileSystem.exists(profiler))
			throw 'hlprof-live is missing: $profiler (rebuild the native runtime)';
		ensureDirectory(Path.directory(capture));
		var bytecodeName = Path.withoutExtension(Path.withoutDirectory(capture)) + ".hl";
		File.copy(output, Path.join([Path.directory(capture), bytecodeName]));
		var port = allocateDiagnosticsPort(), done = new sys.thread.Lock(), readers = 0,
			app = new sys.io.Process(runtime, ["--diagnostics", Std.string(port), "--diagnostics-wait", output].concat(runtimeArguments));
		pumpProcessOutput(app.stdout, Sys.stdout(), done);
		pumpProcessOutput(app.stderr, Sys.stderr(), done);
		readers += 2;
		Sys.println('Profiling $output -> $capture (diagnostics port $port)');
		var profilerProcess = new sys.io.Process(profiler, [
			"--connect-timeout",
			"15",
			"--rate",
			"1000",
			"--alloc-interval",
			"65536",
			"--interval",
			"2000",
			"--top",
			"40",
			"--output",
			capture,
			Std.string(port)
		]);
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
			throw 'Profiler capture did not finalize cleanly (status $profilerStatus)';
		File.saveContent(Path.join([Path.directory(capture), "capture.json"]), Json.stringify({
			schemaVersion: 1,
			kind: "haxeon.capture",
			artifacts: {bytecode: bytecodeName, profile: Path.withoutDirectory(capture)}
		}, null, "  ") + "\n");
		Sys.println('Capture: $capture');
		ProcessRunner.run(profiler, ["report", "--top", "40", capture], projectDirectory, new Map());
		return runtimeStatus;
	}

	static function buildAndroid(home:String, projectConfigPath:String, config:ProjectConfig, output:String, nativeRoot:String):Int {
		configureAndroidEnvironment(home);
		var sdk = Path.join([home, ".tools", "android-sdk"]),
			ndk = Path.join([sdk, "ndk", "30.0.16248370"]);
		if (!FileSystem.exists(sdk) || !FileSystem.exists(ndk))
			throw 'Android SDK/NDK are missing under ${Path.join([home, ".tools", "android-sdk"])}';
		var androidDirectory = Path.join([home, "android"]),
			wrapperJar = Path.join([androidDirectory, "gradle", "wrapper", "gradle-wrapper.jar"]);
		if (!FileSystem.exists(wrapperJar))
			throw 'Android Gradle wrapper is missing: $wrapperJar';

		var arguments = [
			"-classpath",
			wrapperJar,
			"org.gradle.wrapper.GradleWrapperMain",
			"-p",
			androidDirectory,
			"assembleDebug",
			"-PhaxeonProject=" + projectConfigPath,
			"-PhaxeonNativeRoot=" + nativeRoot,
			"-PhaxeonApplicationId=" + config.androidApplicationId,
			"-PhaxeonAppLabel=" + config.androidAppLabel
		];
		var status = ProcessRunner.run(javaExecutable(), arguments, Sys.getCwd(), new Map());
		if (status != 0)
			return status;

		var generated = Path.join([androidDirectory, "app", "build", "outputs", "apk", "debug", "app-debug.apk"]);
		if (!FileSystem.exists(generated))
			throw 'Gradle succeeded but did not create $generated';
		ensureDirectory(Path.directory(output));
		File.copy(generated, output);
		Sys.println('Built android -> $output');
		return 0;
	}

	static function installAndLaunchAndroid(home:String, apk:String, applicationId:String, requestedDevice:Null<String>):Int {
		configureAndroidEnvironment(home);
		var adb = androidExecutable(home, "adb");
		if (!FileSystem.exists(adb))
			throw 'Android adb is missing at $adb';
		var connected = onlineAndroidDevices(adb),
			device:Null<String> = requestedDevice;
		if (device == null) {
			if (connected.length == 0)
				throw 'No online Android device. Start an emulator or connect a device, then run "haxeon devices".';
			if (connected.length > 1)
				throw 'More than one Android device is connected; choose one with "--device SERIAL".';
			device = connected[0].serial;
		} else {
			var selected = false;
			for (connectedDevice in connected)
				if (connectedDevice.serial == device)
					selected = true;
			if (!selected)
				throw 'Android device "$device" is not online; run "haxeon devices" to inspect connected devices.';
		}

		var status = ProcessRunner.run(adb, ["-s", device, "install", "-r", apk], Sys.getCwd(), new Map());
		if (status != 0)
			return status;
		ProcessRunner.run(adb, ["-s", device, "shell", "am", "force-stop", applicationId], Sys.getCwd(), new Map());
		Sys.println('Launching $applicationId on $device');
		return ProcessRunner.run(adb, ["-s", device, "shell", "monkey", "-p", applicationId, "1"], Sys.getCwd(), new Map());
	}

	static function onlineAndroidDevices(adb:String):Array<{serial:String, state:String}> {
		var result = capture(adb, ["devices"]);
		if (result.status != 0)
			throw 'Could not query Android devices: ${result.output}';
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

	static function configureAndroidEnvironment(home:String):Void {
		var sdk = Path.join([home, ".tools", "android-sdk"]);
		Sys.putEnv("ANDROID_SDK_ROOT", sdk);
		Sys.putEnv("ANDROID_HOME", sdk);
		Sys.putEnv("ANDROID_NDK_ROOT", Path.join([sdk, "ndk", "30.0.16248370"]));
		Sys.putEnv("ANDROID_AVD_HOME", Path.join([home, ".tools", "android-avd"]));
		var paths = [
			Path.join([sdk, "platform-tools"]),
			Path.join([sdk, "emulator"]),
			Path.join([sdk, "cmdline-tools", "latest", "bin"]),
			Path.join([sdk, "build-tools", "36.0.0"]),
			Path.join([sdk, "cmake", "3.30.5", "bin"]),
			Path.join([home, ".tools", "gradle", "gradle-9.5.0", "bin"])
		];
		var existing = Sys.getEnv("PATH");
		if (existing != null && existing.length > 0)
			paths.push(existing);
		Sys.putEnv("PATH", paths.join(Sys.systemName() == "Windows" ? ";" : ":"));
	}

	static function androidExecutable(home:String, executable:String):String
		return Path.join([
			home,
			".tools",
			"android-sdk",
			"platform-tools",
			executable + (Sys.systemName() == "Windows" ? ".exe" : "")
		]);

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
		var projectPath = CONFIG_FILE, target:Null<String> = null, output:Null<String> = null, device:Null<String> = null, defines = [],
			runtimeArguments = [], plan = false, explain = false, timings = false, compilerOnly = false, jobs = 4,
			selfHosted = Sys.getEnv("HAXEON_SELF_HOSTED") == "1",
			profile = false, profileOutput:Null<String> = null;
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
			else if (argument == "--compiler-only")
				compilerOnly = true;
			else if (argument == "--self-hosted")
				selfHosted = true;
			else if (argument == "--profile")
				profile = true;
			else if (argument == "--profile-output") {
				if (index >= arguments.length)
					throw 'Option "--profile-output" requires a value';
				profileOutput = arguments[index++];
				profile = true;
			} else if (argument == "--project" || argument == "--target" || argument == "--output" || argument == "--define" || argument == "--device"
				|| argument == "--jobs") {
				if (index >= arguments.length)
					throw 'Option "$argument" requires a value';
				var value = arguments[index++];
				switch argument {
					case "--project":
						projectPath = value;
					case "--target":
						target = value;
					case "--output":
						output = value;
					case "--define":
						defines.push(value);
					case "--device":
						device = value;
					case "--jobs":
						var parsedJobs = Std.parseInt(value);
						if (parsedJobs == null || parsedJobs < 1)
							throw 'Option "--jobs" requires a positive integer';
						jobs = parsedJobs;
					case _:
				}
			} else if (StringTools.startsWith(argument, "--project="))
				projectPath = argument.substr("--project=".length);
			else if (StringTools.startsWith(argument, "--target="))
				target = argument.substr("--target=".length);
			else if (StringTools.startsWith(argument, "--output="))
				output = argument.substr("--output=".length);
			else if (StringTools.startsWith(argument, "--device="))
				device = argument.substr("--device=".length);
			else if (StringTools.startsWith(argument, "--jobs=")) {
				var parsedJobs = Std.parseInt(argument.substr("--jobs=".length));
				if (parsedJobs == null || parsedJobs < 1)
					throw 'Option "--jobs" requires a positive integer';
				jobs = parsedJobs;
			} else if (StringTools.startsWith(argument, "--define="))
				defines.push(argument.substr("--define=".length));
			else if (StringTools.startsWith(argument, "--profile-output=")) {
				profileOutput = argument.substr("--profile-output=".length);
				profile = true;
			} else
				throw 'Unknown build option "$argument"';
		}
		if (projectPath.length == 0)
			throw 'Option "--project" requires a value';
		return {
			projectPath: projectPath,
			target: target,
			output: output,
			device: device,
			defines: defines,
			runtimeArguments: runtimeArguments,
			plan: plan,
			explain: explain,
			timings: timings,
			compilerOnly: compilerOnly,
			jobs: jobs,
			selfHosted: selfHosted,
			profile: profile,
			profileOutput: profileOutput
		};
	}

	static function parsePackageOptions(arguments:Array<String>, allowLocked:Bool, command:String):PackageOptions {
		var projectPath = CONFIG_FILE, locked = false, index = 0;
		while (index < arguments.length) {
			var argument = arguments[index++];
			if (argument == "--locked") {
				if (!allowLocked)
					throw 'Unknown $command option "--locked"';
				locked = true;
			} else if (argument == "--project") {
				if (index >= arguments.length)
					throw 'Option "--project" requires a value';
				projectPath = arguments[index++];
			} else if (StringTools.startsWith(argument, "--project="))
				projectPath = argument.substr("--project=".length);
			else
				throw 'Unknown $command option "$argument"';
		}
		return {projectPath: projectPath, locked: locked};
	}

	static function parseAddOptions(arguments:Array<String>):AddOptions {
		var projectPath = CONFIG_FILE, name:Null<String> = null, git:Null<String> = null, rev:Null<String> = null, index = 0;
		while (index < arguments.length) {
			var argument = arguments[index++];
			if (argument == "--git" || argument == "--rev" || argument == "--name" || argument == "--project") {
				if (index >= arguments.length)
					throw 'Option "$argument" requires a value';
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
					case _:
				}
			} else if (StringTools.startsWith(argument, "--git="))
				git = argument.substr("--git=".length);
			else if (StringTools.startsWith(argument, "--rev="))
				rev = argument.substr("--rev=".length);
			else if (StringTools.startsWith(argument, "--name="))
				name = argument.substr("--name=".length);
			else if (StringTools.startsWith(argument, "--project="))
				projectPath = argument.substr("--project=".length);
			else if (StringTools.startsWith(argument, "--"))
				throw 'Unknown add option "$argument"';
			else if (name == null)
				name = argument;
			else
				throw 'Unexpected add argument "$argument"';
		}
		if (git == null || git.length == 0)
			throw 'Option "--git" requires a non-empty URL';
		if (rev == null || rev.length == 0)
			throw 'Option "--rev" requires a non-empty ref';
		return {
			projectPath: projectPath,
			name: name,
			git: git,
			rev: rev
		};
	}

	static function parsePublishOptions(arguments:Array<String>):PublishOptions {
		var projectPath = CONFIG_FILE, registry:Null<String> = null, version:Null<String> = null, index = 0;
		while (index < arguments.length) {
			var argument = arguments[index++];
			if (argument == "--registry" || argument == "--version" || argument == "--project") {
				if (index >= arguments.length)
					throw 'Option "$argument" requires a value';
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
				throw 'Unknown publish option "$argument"';
		}
		if (registry == null || registry.length == 0)
			throw 'Option "--registry" requires a non-empty registry name';
		if (version == null || version.length == 0)
			throw 'Option "--version" requires an exact package version';
		return {projectPath: projectPath, registry: registry, version: version};
	}

	static function discoverProject(manifestPath:String, ?target:Target):ResolvedProject {
		var lockPath = lockfilePath(manifestPath),
			lockfile = FileSystem.exists(lockPath) ? PackageLockfile.parse(lockPath, File.getContent(lockPath)) : null;
		return resolveProject(manifestPath, lockfile, lockfile != null, target);
	}

	static function resolveProject(manifestPath:String, lockfile:Null<PackageLockfile>, locked:Bool, ?target:Target):ResolvedProject {
		return new PackageResolver(new ProjectSourceAcquirer(SourceCache.root())).resolve(manifestPath, lockfile, locked, target);
	}

	static function lockfilePath(manifestPath:String):String
		return Path.join([Path.directory(manifestPath), "haxeon.lock"]);

	static function inferPackageName(url:String):String {
		var value = url;
		while (StringTools.endsWith(value, "/"))
			value = value.substr(0, value.length - 1);
		var slash = value.lastIndexOf("/");
		value = slash < 0 ? value : value.substr(slash + 1);
		return StringTools.endsWith(value, ".git") ? value.substr(0, value.length - 4) : value;
	}

	static function printTree(packageValue:ResolvedPackage, project:ResolvedProject, prefix:String, active:Map<String, Bool>):Void {
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

	static function packagePath(current:ResolvedPackage, target:String, project:ResolvedProject, active:Map<String, Bool>):Null<Array<String>> {
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

	static function loadConfig(path:String):ProjectConfig {
		var raw:Dynamic;
		try {
			raw = Json.parse(File.getContent(path));
		} catch (error:Dynamic) {
			throw 'Could not parse $path: ${Std.string(error)}';
		}
		if (raw == null || !Reflect.isObject(raw))
			throw '$path must contain a JSON object';
		var version:Dynamic = Reflect.field(raw, "version");
		if (version != null && Std.int(version) != 1)
			throw 'Unsupported $CONFIG_FILE version "$version"';
		var entry = requiredString(raw, "entry", path),
			sources = stringArray(raw, "sources", path, []),
			sourceRoots = stringArray(raw, "sourceRoots", path, ["src"]),
			target = optionalString(raw, "target", "host"),
			defines = stringArray(raw, "defines", path, []),
			outputDir = optionalString(raw, "outputDir", "build");
		var android:Dynamic = Reflect.field(raw, "android"),
			androidApplicationId = "org.haxeon.android",
			androidAppLabel = "Haxeon";
		if (android != null) {
			if (!Reflect.isObject(android) || Type.getClassName(Type.getClass(android)) == "Array")
				throw '$path "android" must be an object';
			androidApplicationId = optionalString(android, "applicationId", androidApplicationId);
			androidAppLabel = optionalString(android, "label", androidAppLabel);
		}
		if (!isAndroidApplicationId(androidApplicationId))
			throw '$path "android.applicationId" must be a dotted Java package name, such as "org.example.game"';
		if (sources.length == 0)
			throw '$path must list at least one source in "sources"';
		if (sourceRoots.length == 0)
			throw '$path must list at least one path in "sourceRoots"';
		try {
			Target.parse(target);
		} catch (error:Dynamic) {
			throw '$path has an invalid target "$target": ${Std.string(error)}';
		}
		return {
			entry: entry,
			sources: sources,
			sourceRoots: sourceRoots,
			target: target,
			defines: defines,
			outputDir: outputDir,
			androidApplicationId: androidApplicationId,
			androidAppLabel: androidAppLabel
		};
	}

	static function isAndroidApplicationId(value:String):Bool {
		var parts = value.split(".");
		if (parts.length < 2)
			return false;
		for (part in parts) {
			if (part.length == 0 || !isAsciiLetter(part.charCodeAt(0)) && part.charCodeAt(0) != 95)
				return false;
			for (index in 1...part.length) {
				var code = part.charCodeAt(index);
				if (!isAsciiLetter(code) && (code < 48 || code > 57) && code != 95)
					return false;
			}
		}
		return true;
	}

	static function isAsciiLetter(code:Int):Bool
		return (code >= 65 && code <= 90) || (code >= 97 && code <= 122);

	static function requiredString(raw:Dynamic, field:String, path:String):String {
		var value:Dynamic = Reflect.field(raw, field);
		if (!Std.isOfType(value, String) || (cast value : String).length == 0)
			throw '$path requires a non-empty "$field" string';
		return cast value;
	}

	static function optionalString(raw:Dynamic, field:String, fallback:String):String {
		var value:Dynamic = Reflect.field(raw, field);
		if (value == null)
			return fallback;
		if (!Std.isOfType(value, String) || (cast value : String).length == 0)
			throw '"$field" must be a non-empty string';
		return cast value;
	}

	static function stringArray(raw:Dynamic, field:String, path:String, fallback:Array<String>):Array<String> {
		var value:Dynamic = Reflect.field(raw, field);
		if (value == null)
			return fallback.copy();
		if (!Std.isOfType(value, Array))
			throw '$path "$field" must be an array of strings';
		var result:Array<String> = [];
		for (item in (cast value : Array<Dynamic>)) {
			if (!Std.isOfType(item, String) || (cast item : String).length == 0)
				throw '$path "$field" must contain only non-empty strings';
			result.push(cast item);
		}
		return result;
	}

	static function defaultOutput(config:ProjectConfig, projectDirectory:String, target:String):String {
		var output = target == "host" ? "main.hl" : target == "wasm32" ? "main.wasm" : "app-debug.apk";
		return resolvePath(Path.join([config.outputDir, target, output]), projectDirectory);
	}

	static function configureRuntimeLibraryPath(home:String, ?extraDirectories:Array<String>):Void {
		var directories = [Path.join([home, "out"]), Path.join([home, ".tools", "hashlink"])];
		if (extraDirectories != null)
			directories = directories.concat(extraDirectories);
		var variable = switch Sys.systemName() {
			case "Windows": "PATH";
			case "Mac": "DYLD_LIBRARY_PATH";
			case _: "LD_LIBRARY_PATH";
		};
		var existing = Sys.getEnv(variable);
		if (existing != null && existing.length > 0)
			directories.push(existing);
		Sys.putEnv(variable, directories.join(Sys.systemName() == "Windows" ? ";" : ":"));
	}

	static function haxeonHome():String {
		var home = Sys.getEnv("HAXEON_HOME");
		if (home == null || home.length == 0)
			throw "HAXEON_HOME is not set; run the CLI through scripts/haxeon";
		return FileSystem.fullPath(home);
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

	static function executableSuffix():String
		return Sys.systemName() == "Windows" ? ".exe" : "";

	static function usage(status:Int = 0):Int {
		Sys.println("Usage: haxeon <command> [options]");
		Sys.println("  init [--entry Main] [--target host|wasm32|android]");
		Sys.println("  add --git URL --rev REF [NAME]  Add a Git package dependency");
		Sys.println("  install [--locked]              Resolve dependencies and write haxeon.lock");
		Sys.println("  update                          Re-resolve refs and rewrite haxeon.lock");
		Sys.println("  publish --registry NAME --version VERSION  Publish an immutable local release");
		Sys.println("  package check [--project PATH]     Validate the resolved package graph");
		Sys.println("  tree                            Show the resolved package graph");
		Sys.println("  why PACKAGE                     Explain a dependency path");
		Sys.println("  doctor                         Check the local compiler and HashLink runtime");
		Sys.println("  platforms                      Show targets exposed by this CLI");
		Sys.println("  devices                        List connected Android devices");
		Sys.println("  fmt [options] PATH...          Format Haxe source files");
		Sys.println("       [--check] [--stdin]      Check files or format stdin");
		Sys.println("       [--line-width N]         Set the formatter column limit (default 120)");
		Sys.println("  build [--target TARGET]        Build project in haxeon.json (host, wasm32, android)");
		Sys.println("       [--plan] [--explain] [--timings] [--compiler-only] [--jobs COUNT]");
		Sys.println("                                    Inspect planning details or timings");
		Sys.println("       [--self-hosted]              Compile with bootstrap/compiler.hl instead of reference Haxe");
		Sys.println("  run [--target TARGET] [-- args] Build and launch (host or Android)");
		Sys.println("       [--profile]                  Launch under hl --diagnostics and capture with hlprof-live");
		Sys.println("       [--profile-output PATH]      Write the HLPC capture to PATH (implies --profile)");
		Sys.println("  heap inspect BYTECODE DUMP      Inspect a HashLink heap snapshot with matching bytecode");
		Sys.println("       [--capture DIR] [--report PATH]  Read a capture manifest or choose a report path");
		Sys.println("  --device SERIAL                Select Android device for run");
		Sys.println("  --project PATH                 Select a haxeon.json file");
		Sys.println("  --output PATH                  Override the build output path");
		Sys.println("  --define NAME[=VALUE]          Add a conditional compilation define");
		return status;
	}
}
