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
				case "doctor": doctor(arguments);
				case "platforms": platforms(arguments);
				case "devices": devices(arguments);
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
		if (target != "host" && target != "wasm32" && target != "android")
			throw 'Unsupported init target "$target"';

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
		if (target == "android")
			Reflect.setField(config, "android", {applicationId: "org.haxeon.android", label: "Haxeon"});
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
		var config = loadConfig(projectConfigPath);
		var target = options.target == null ? config.target : options.target;
		if (target != "host" && target != "wasm32" && target != "android")
			throw 'Unsupported CLI target "$target". Supported targets are "host", "wasm32", and "android".';
		if (launch && target == "wasm32")
			throw 'The "$target" target can be built, but this CLI has no runner for it yet.';
		if (!launch && options.device != null)
			throw 'Option "--device" is only valid with "haxeon run --target android"';
		if (target != "android" && options.device != null)
			throw 'Option "--device" requires "--target android"';

		var home = haxeonHome();
		if (target == "android") {
			var androidOutput = options.output == null ? defaultOutput(config, projectDirectory, "android") : resolvePath(options.output, projectDirectory);
			var status = buildAndroid(home, projectConfigPath, config, androidOutput);
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

	static function buildAndroid(home:String, projectConfigPath:String, config:ProjectConfig, output:String):Int {
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
			"-PhaxeonApplicationId=" + config.androidApplicationId,
			"-PhaxeonAppLabel=" + config.androidAppLabel
		];
		var status = Sys.command(javaExecutable(), arguments);
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

		var status = Sys.command(adb, ["-s", device, "install", "-r", apk]);
		if (status != 0)
			return status;
		Sys.command(adb, ["-s", device, "shell", "am", "force-stop", applicationId]);
		Sys.println('Launching $applicationId on $device');
		return Sys.command(adb, ["-s", device, "shell", "monkey", "-p", applicationId, "1"]);
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
		var projectPath = CONFIG_FILE, target:Null<String> = null, output:Null<String> = null, device:Null<String> = null, defines = [], runtimeArguments = [];
		var index = 0;
		while (index < arguments.length) {
			var argument = arguments[index++];
			if (argument == "--") {
				runtimeArguments = arguments.slice(index);
				break;
			}
			if (argument == "--project" || argument == "--target" || argument == "--output" || argument == "--define" || argument == "--device") {
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
			device: device,
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
		if (target != "host" && target != "wasm32" && target != "android")
			throw '$path target must be "host", "wasm32", or "android"';
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
		Sys.println("  init [--entry Main] [--target host|wasm32|android]");
		Sys.println("  doctor                         Check the local compiler and HashLink runtime");
		Sys.println("  platforms                      Show targets exposed by this CLI");
		Sys.println("  devices                        List connected Android devices");
		Sys.println("  build [--target TARGET]        Build project in haxeon.json (host, wasm32, android)");
		Sys.println("  run [--target TARGET] [-- args] Build and launch (host or Android)");
		Sys.println("  --device SERIAL                Select Android device for run");
		Sys.println("  --project PATH                 Select a haxeon.json file");
		Sys.println("  --output PATH                  Override the build output path");
		Sys.println("  --define NAME[=VALUE]          Add a conditional compilation define");
		return status;
	}
}
