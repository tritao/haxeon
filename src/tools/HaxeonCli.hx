package tools;

import haxe.Json;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;

private typedef ProjectConfig = {
	final entry:String;
	final sources:Array<String>;
	final sourceRoots:Array<String>;
	final target:String;
	final defines:Array<String>;
	final outputDir:String;
}

private typedef BuildOptions = {
	final projectPath:String;
	final target:Null<String>;
	final output:Null<String>;
	final defines:Array<String>;
	final runtimeArguments:Array<String>;
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
				case "doctor": doctor(arguments);
				case "platforms": platforms(arguments);
				case "build": build(arguments, false);
				case "run": build(arguments, true);
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
		var entry = "Main";
		var index = 0;
		while (index < arguments.length) {
			var argument = arguments[index++];
			if (argument == "--entry") {
				if (index >= arguments.length)
					throw 'Option "--entry" requires a value';
				entry = arguments[index++];
			} else if (StringTools.startsWith(argument, "--entry="))
				entry = argument.substr("--entry=".length);
			else
				throw 'Unknown init option "$argument"';
		}
		if (entry.length == 0)
			throw 'Option "--entry" requires a value';

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
			File.saveContent(absoluteSource, source + "function main():Int return 0;\n");
		}

		var config = {
			version: 1,
			entry: entry,
			sources: [sourcePath],
			sourceRoots: ["src"],
			target: "host",
			defines: [],
			outputDir: "build"
		};
		File.saveContent(configPath, Json.stringify(config, null, "\t") + "\n");
		Sys.println('Created $CONFIG_FILE and $sourcePath');
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
		var missingRequired = false;

		missingRequired = reportPath("pinned Haxe compiler", haxePath, true) || missingRequired;
		missingRequired = reportPath("HashLink runtime", hashlinkPath, true) || missingRequired;
		missingRequired = reportPath("Haxeon runtime library", nativeRuntimePath, true) || missingRequired;
		reportPath("self-hosted compiler", compilerPath, false);
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
		Sys.println("Outside this CLI:");
		Sys.println("  Android  use scripts/build-android.sh and the adb patch/reload scripts");
		return 0;
	}

	static function build(arguments:Array<String>, launch:Bool):Int {
		var options = parseBuildOptions(arguments),
			projectConfigPath = resolvePath(options.projectPath, Sys.getCwd());
		if (!FileSystem.exists(projectConfigPath))
			throw 'Project file not found: $projectConfigPath (run "haxeon init" to create one)';
		var projectDirectory = Path.directory(projectConfigPath);
		if (projectDirectory == "")
			projectDirectory = Sys.getCwd();
		var config = loadConfig(projectConfigPath);
		var target = options.target == null ? config.target : options.target;
		if (target != "host" && target != "wasm32")
			throw 'Unsupported CLI target "$target". Supported targets are "host" and "wasm32".';
		if (launch && target != "host")
			throw 'The "$target" target can be built, but this CLI has no runner for it yet.';

		var output = options.output == null ? defaultOutput(config, projectDirectory, target) : resolvePath(options.output, projectDirectory);
		ensureDirectory(Path.directory(output));
		var home = haxeonHome(),
			compiler = Path.join([home, ".tools", "haxe", "haxe" + executableSuffix()]);
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

		var previousDirectory = Sys.getCwd(), compileStatus:Int;
		try {
			// CompilerDriver resolves Haxeon's bundled stdlib relative to the repo.
			Sys.setCwd(home);
			compileStatus = Sys.command(compiler, compilerArguments);
		} catch (error:Dynamic) {
			Sys.setCwd(previousDirectory);
			throw error;
		}
		Sys.setCwd(previousDirectory);
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
		Sys.setCwd(projectDirectory);
		return Sys.command(hashlink, [output].concat(options.runtimeArguments));
	}

	static function parseBuildOptions(arguments:Array<String>):BuildOptions {
		var projectPath = CONFIG_FILE, target:Null<String> = null, output:Null<String> = null, defines = [], runtimeArguments = [];
		var index = 0;
		while (index < arguments.length) {
			var argument = arguments[index++];
			if (argument == "--") {
				runtimeArguments = arguments.slice(index);
				break;
			}
			if (argument == "--project" || argument == "--target" || argument == "--output" || argument == "--define") {
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
					case _:
				}
			} else if (StringTools.startsWith(argument, "--project="))
				projectPath = argument.substr("--project=".length);
			else if (StringTools.startsWith(argument, "--target="))
				target = argument.substr("--target=".length);
			else if (StringTools.startsWith(argument, "--output="))
				output = argument.substr("--output=".length);
			else if (StringTools.startsWith(argument, "--define="))
				defines.push(argument.substr("--define=".length));
			else
				throw 'Unknown build option "$argument"';
		}
		if (projectPath.length == 0)
			throw 'Option "--project" requires a value';
		return {
			projectPath: projectPath,
			target: target,
			output: output,
			defines: defines,
			runtimeArguments: runtimeArguments
		};
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
		if (sources.length == 0)
			throw '$path must list at least one source in "sources"';
		if (sourceRoots.length == 0)
			throw '$path must list at least one path in "sourceRoots"';
		if (target != "host" && target != "wasm32")
			throw '$path target must be "host" or "wasm32"';
		return {
			entry: entry,
			sources: sources,
			sourceRoots: sourceRoots,
			target: target,
			defines: defines,
			outputDir: outputDir
		};
	}

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
		var extension = target == "host" ? "hl" : "wasm";
		return resolvePath(Path.join([config.outputDir, target, "main." + extension]), projectDirectory);
	}

	static function configureRuntimeLibraryPath(home:String):Void {
		var directories = [Path.join([home, "out"]), Path.join([home, ".tools", "hashlink"])];
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
		Sys.println("  init [--entry Main]            Create haxeon.json and a starter source");
		Sys.println("  doctor                         Check the local compiler and HashLink runtime");
		Sys.println("  platforms                      Show targets exposed by this CLI");
		Sys.println("  build [--target host|wasm32]   Compile the project in haxeon.json");
		Sys.println("  run [--target host] [-- args]  Build and launch on the current host");
		Sys.println("  --project PATH                 Select a haxeon.json file");
		Sys.println("  --output PATH                  Override the build output path");
		Sys.println("  --define NAME[=VALUE]          Add a conditional compilation define");
		return status;
	}
}
