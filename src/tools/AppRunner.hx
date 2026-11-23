package tools;

import build.HaxeonProjectBuild;
import build.HaxeonSdk;
import build.Target;
import build.execution.ProcessRunner;
import build.native.MsvcEnvironment;
import build.native.NativeCMakeProvider;
import build.native.NativeCompilerCache;
import compiler.core.UsageError;
import haxe.io.Path;
import project.PackageManifest.AppManifest;
import project.ResolvedProject;
import sys.FileSystem;
import sys.io.File;

/**
 * An app's build through its runner project (docs/design/PROJECT_BUILDS.md): the generated fragment the runner includes
 * (`build/generated/PLATFORM/haxeon.cmake`), and the runner's CMake build, which makes the app's executable from the SDK's VM,
 * the compiled module and every native package in one graph.
 */
class AppRunner {
	/** The platform this machine builds for, as `[app].platforms` names it. */
	public static function hostPlatform():String
		return switch Sys.systemName() {
			case "Windows": "windows";
			case "Mac": "macos";
			case _: "linux";
		};

	/** The runner directory of `platform`, checked: the app lists the platform and has its runner. */
	public static function runnerDirectory(project:ResolvedProject, app:AppManifest, platform:String):String {
		if (app.platforms.indexOf(platform) < 0)
			throw new UsageError('This app does not build for $platform ([app].platforms is [${app.platforms.join(", ")}]); '
				+ 'add it with: haxeon create . --platforms $platform');
		var directory = Path.join([project.root, platform]);
		var entry = switch platform {
			case "android": "settings.gradle";
			case "web": "index.html";
			case _: "CMakeLists.txt";
		};
		if (!FileSystem.exists(Path.join([directory, entry])))
			throw new UsageError('This app has no $platform runner ($directory/$entry); restore it with: haxeon create .');
		return directory;
	}

	/** The executable the runner's build makes: in a bundle on macOS (cmake/sdk/HaxeonApp.cmake). */
	public static function executable(project:ResolvedProject, platform:String):String {
		var directory = Path.join([buildDirectory(project, platform), "app"]), name = project.rootPackage.name;
		return switch platform {
			case "windows": Path.join([directory, name + ".exe"]);
			case "macos": Path.join([directory, name + ".app", "Contents", "MacOS", name]);
			case _: Path.join([directory, name]);
		};
	}

	/**
	 * Writes the fragment for `platform` and builds the runner: configured once, then built by CMake, which decides what is out of
	 * date. `module` is the compiled program: bytecode the VM runs, or with `aheadOfTime` the C written at `module.c/`, which the
	 * runner compiles into the executable. Returns the build's exit status.
	 */
	public static function build(project:ResolvedProject, home:String, platform:String, module:String, aheadOfTime:Bool,
			quiet:Bool):Int {
		var app = project.manifest.app;
		if (app == null)
			throw new UsageError("This project is not an app: it has no [app] section");
		var runner = runnerDirectory(project, app, platform),
			fragment = writeFragment(project, app, home, platform, module, aheadOfTime);
		// The SDK's Windows libraries are MSVC's (HaxeonConfig.cmake selects lib/windows-ARCH-msvc), so the runner builds with
		// MSVC, in its developer environment, whatever compiler comes first on PATH.
		var msvc = platform == "windows";
		if (msvc && !MsvcEnvironment.ensure(Target.detectHost().arch))
			throw new UsageError("Building a Windows app needs MSVC: install Visual Studio's C++ tools");
		var ninja = NativeCMakeProvider.ninjaExecutable(home);
		var binary = buildDirectory(project, platform),
			configure = !FileSystem.exists(Path.join([
				binary,
				"CMakeCache.txt"
			]));
		if (configure) {
			var status = ProcessRunner.run("cmake", [
				"-S",
				runner,
				"-B",
				binary,
				"-G",
				"Ninja",
				"-DCMAKE_BUILD_TYPE=Release",
				'-DHAXEON_GENERATED_DIR=${Path.directory(fragment)}'
			].concat(Path.isAbsolute(ninja) ? ['-DCMAKE_MAKE_PROGRAM=$ninja'] : [])
				.concat(msvc ? ["-DCMAKE_C_COMPILER=cl", "-DCMAKE_CXX_COMPILER=cl"] : [])
				.concat(NativeCompilerCache.configureArguments(NativeCompilerCache.executable(home))),
				project.root, null, !quiet);
			if (status != 0)
				return status;
		}
		return ProcessRunner.run("cmake", ["--build", binary], project.root, null, !quiet);
	}

	public static function writeFragment(project:ResolvedProject, app:AppManifest, home:String, platform:String,
			module:String, aheadOfTime:Bool = false):String {
		var fragment = Path.join([
			HaxeonProjectBuild.outputDirectory(project, false),
			"generated",
			platform,
			"haxeon.cmake"
		]);
		writeIfChanged(fragment, fragmentText(project, app, home, module, aheadOfTime));
		return fragment;
	}

	public static function webHost(project:ResolvedProject, home:String):Null<String> {
		var needsHost = false;
		for (resolved in project.packages.packages) {
			if (resolved.manifest.native == null)
				continue;
			var cmake = resolved.manifest.native.cmake;
			if (cmake == null || (cmake.target != "nativekit_ui" && cmake.target != "haxeon_nativekit"))
				throw new UsageError('Web app runners cannot build native package "${resolved.name}"');
			needsHost = true;
		}
		if (!needsHost)
			return null;
		var directory = Path.join([home, "platforms", "web", "ui"]);
		if (!FileSystem.exists(Path.join([directory, "nativekit_haxeon_memory_contract.json"])))
			throw new UsageError("This SDK is missing the WebGL2 UI host. For a source SDK, install Emscripten with vendor/nativekit/tools/setup-web.sh and rebuild the SDK.");
		return directory;
	}

	public static function bundleWeb(project:ResolvedProject, app:AppManifest, home:String, target:Target,
			module:String, host:Null<String>):String {
		var platform = "web",
			runner = runnerDirectory(project, app, platform),
			targetName = target.toString(),
			bundle = Path.join([buildDirectory(project, platform), targetName]);
		writeFragment(project, app, home, platform, module);
		FileSystem.createDirectory(bundle);
		var status = ProcessRunner.run("cmake", ["-E", "copy_directory", runner, bundle], project.root, null);
		if (status != 0)
			throw new UsageError('Could not copy the web runner into $bundle');
		File.copy(Path.join([home, "platforms", "web", "haxeon-host.js"]), Path.join([bundle, "haxeon-host.js"]));
		if (host != null && ProcessRunner.run("cmake", ["-E", "copy_directory", host, Path.join([bundle, "ui"])],
			project.root, null) != 0)
			throw new UsageError('Could not copy the WebGL2 UI host into $bundle');
		var bundledModule = Path.join([bundle, "main.wasm"]);
		if (module != bundledModule)
			File.copy(module, bundledModule);
		writeIfChanged(Path.join([bundle, "haxeon-build.js"]), 'export const target = "$targetName";\n'
			+ 'export const module = new URL("./main.wasm", import.meta.url);\n');
		return Path.join([bundle, "index.html"]);
	}

	static function buildDirectory(project:ResolvedProject, platform:String):String
		return Path.join([HaxeonProjectBuild.outputDirectory(project, false), platform]);

	/**
	 * The fragment: data only (docs/design/SDK_LAYOUT.md). The app's fields and module, the SDK's CMake package as a hint for the
	 * runner's find_package(Haxeon), and each native package, dependencies first, for haxeon_add_app to add to the graph.
	 */
	static function fragmentText(project:ResolvedProject, app:AppManifest, home:String, module:String,
			aheadOfTime:Bool):String {
		var lines = [
			"# Generated by haxeon build for this app's runner (docs/design/PROJECT_BUILDS.md); written again by every build, so",
			"# edits are lost. The runner's CMakeLists.txt includes it, then find_package(Haxeon) and haxeon_add_app read it.",
			'set(HAXEON_APP_NAME ${quote(app.name)})',
			'set(HAXEON_APP_ID ${quote(app.id)})',
			'set(HAXEON_APP_VERSION ${quote(app.version)})',
			// One of the two: the bytecode the VM runs, or the program's C, compiled ahead of time.
			'set(HAXEON_MODULE ${aheadOfTime ? '""' : quote(module)})',
			'set(HAXEON_MODULE_C ${aheadOfTime ? quote(module + ".c") : '""'})',
			'set(Haxeon_DIR ${quote(HaxeonSdk.cmakeDirectory(home))})'
		];
		var names:Array<String> = [];
		for (resolved in project.packages.packages) {
			var native = resolved.manifest.native;
			if (native == null)
				continue;
			if (native.cmake == null)
				throw new UsageError('Package "${resolved.name}" has native sources without a CMake project, which an app\'s runner '
					+ 'cannot build yet; give it [native.cmake]');
			names.push(resolved.name);
			var prefix = 'HAXEON_PACKAGE_${resolved.name}';
			lines.push('set(${prefix}_SOURCE ${quote(Path.join([resolved.root, native.cmake.source]))})');
			lines.push('set(${prefix}_TARGET ${native.cmake.target})');
		}
		lines.push('set(HAXEON_PACKAGES ${names.join(" ")})');
		return lines.join("\n") + "\n";
	}

	static function quote(text:String):String
		return '"' + StringTools.replace(StringTools.replace(text, "\\", "/"), "\"", "\\\"") + '"';

	static function writeIfChanged(path:String, text:String):Void {
		if (FileSystem.exists(path) && File.getContent(path) == text)
			return;
		FileSystem.createDirectory(Path.directory(path));
		File.saveContent(path, text);
	}
}
