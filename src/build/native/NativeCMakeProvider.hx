package build.native;

import build.Artifact;
import build.Artifact.ArtifactKind;
import build.ArtifactId;
import build.BuildEnvironment.BuildProfile;
import build.lowering.LoweringContext;
import build.execution.ActionId;
import build.execution.ExecutionAction;
import build.execution.ExecutionAction.ActionKind;
import build.Target;
import build.Target.TargetAbi;
import build.Target.TargetOs;
import haxe.io.Path;
import project.FfiManifest.ResolvedFfiImport;
import project.ResolvedPackage;

/** Delegates an existing CMake project as one coarse native provider. */
class NativeCMakeProvider {
	public static function lowerPackage(resolvedPackage:ResolvedPackage, artifacts:Array<Artifact>, context:LoweringContext):{
		actions:Array<ExecutionAction>,
		artifactActions:Map<String, Array<ActionId>>
	} {
		var native = resolvedPackage.manifest.native;
		if (native == null || native.cmake == null)
			throw 'Package "${resolvedPackage.name}" has no native.cmake provider';
		var source = Path.normalize(Path.join([resolvedPackage.root, native.cmake.source])),
			layout = context.layout,
			cmakeInputs = [Path.join([source, "CMakeLists.txt"])].concat(resolvedPackage.nativeCMakeInputs),
			ninja = ninjaAvailable(context.environment.target, context.compilerHome),
			ninjaProgram = ninjaExecutable(context.compilerHome), // CMake rejects a cache created by another generator, so Ninja trees get their own directory.
			buildTree = ninja ? "cmake-ninja" : "cmake", // Workspace builds identify a CMake tree by what it builds, so packages that request the same
		// (source, target) pair share one configure, one build and one set of runtime libraries.
			shared = context.sharedNative,
			identity = shared ? sharedName(source, native.cmake.target, context.environment.projectRoot) : resolvedPackage.name,
			sharedRoot = shared ? layout.sharedCMakeRoot(identity) : null,
			buildDirectory = shared ? Path.join([sharedRoot, buildTree]) : Path.join([layout.packageRoot(resolvedPackage.name), buildTree]),
			legacyOutput = shared ? (native.cmake.library == null ? Path.join([sharedRoot, "out", native.cmake.target]) : Path.join([
				sharedRoot,
				"out",
				(context.environment.target.os == TargetOs.Windows ? "" : "lib") + native.cmake.library + context.environment.toolchain.sharedLibrarySuffix
			])) : (native.cmake.library == null ? layout.haxeonNativeLibraryPath(resolvedPackage.name) : layout.cmakeSharedLibraryPath(resolvedPackage.name,
				native.cmake.library)),
			outputDirectory = Path.directory(legacyOutput),
			outputs = native.cmake.libraries.length == 0 ? [legacyOutput] : [
				for (name in native.cmake.libraries)
					Path.join([
						outputDirectory,
						(context.environment.target.os == TargetOs.Windows ? "" : "lib") + name + context.environment.toolchain.sharedLibrarySuffix
					])
			],
			runDirectory = shared ? source : resolvedPackage.root,
			configuration = context.environment.profile == BuildProfile.Debug ? "Debug" : "Release",
			configureArguments = [
				"-S",
				source,
				"-B",
				buildDirectory,
				"-DHAXEON_NATIVE_OUTPUT_DIR=" + outputDirectory,
				"-DHAXEON_TARGET=" + context.environment.target.toString(),
				"-DCMAKE_BUILD_TYPE=" + configuration
			].concat(ninja ? ["-G", "Ninja"].concat(Path.isAbsolute(ninjaProgram) ? ["-DCMAKE_MAKE_PROGRAM=" + ninjaProgram] : []) : []),
			windowsNinja = ninja && context.environment.target.os == TargetOs.Windows,
			configureId = new ActionId('native-cmake-configure:$identity:${context.environment.target.toString()}'),
			buildId = new ActionId('native-cmake-build:$identity:${context.environment.target.toString()}'),
			toolchain = new NativeToolchain(context.environment),
			ccache = NativeCompilerCache.executable(),
			compilerCache = NativeCompilerCache.environment(ccache, context.environment.projectRoot, source);
		discardCacheOfOtherSource(buildDirectory, source);
		// MSVC, as the Visual Studio generator would use, even when CC or CXX names another compiler.
		if (windowsNinja)
			for (argument in ["-DCMAKE_C_COMPILER=cl", "-DCMAKE_CXX_COMPILER=cl"])
				configureArguments.push(argument);
		for (argument in NativeCompilerCache.configureArguments(ccache))
			configureArguments.push(argument);
		if (native.cmake.libraries.length > 0) {
			configureArguments.push("-DCMAKE_LIBRARY_OUTPUT_DIRECTORY=" + outputDirectory);
			configureArguments.push("-DCMAKE_RUNTIME_OUTPUT_DIRECTORY=" + outputDirectory);
		}
		if (context.environment.target.os == TargetOs.Windows) {
			configureArguments.push("-DCMAKE_ARCHIVE_OUTPUT_DIRECTORY=" + outputDirectory);
			configureArguments.push("-DCMAKE_ARCHIVE_OUTPUT_DIRECTORY_DEBUG=" + outputDirectory);
			configureArguments.push("-DCMAKE_ARCHIVE_OUTPUT_DIRECTORY_RELEASE=" + outputDirectory);
			configureArguments.push("-DCMAKE_LIBRARY_OUTPUT_DIRECTORY=" + outputDirectory);
			configureArguments.push("-DCMAKE_LIBRARY_OUTPUT_DIRECTORY_DEBUG=" + outputDirectory);
			configureArguments.push("-DCMAKE_LIBRARY_OUTPUT_DIRECTORY_RELEASE=" + outputDirectory);
			configureArguments.push("-DCMAKE_RUNTIME_OUTPUT_DIRECTORY=" + outputDirectory);
			configureArguments.push("-DCMAKE_RUNTIME_OUTPUT_DIRECTORY_DEBUG=" + outputDirectory);
			configureArguments.push("-DCMAKE_RUNTIME_OUTPUT_DIRECTORY_RELEASE=" + outputDirectory);
		}
		// haxeon-native.cmake keeps frame pointers off Windows, for the sampling profiler, and instruments when asked.
		configureArguments.push("-DCMAKE_PROJECT_INCLUDE=" + Path.join([context.compilerHome, "cmake", "haxeon-native.cmake"]));
		for (file in ["haxeon-native.cmake", "haxeon-frame-pointers.cmake"])
			cmakeInputs.push(Path.join([context.compilerHome, "cmake", file]));
		var instrumenting = instrumentArguments(context);
		for (argument in instrumenting)
			configureArguments.push(argument);
		if (instrumenting.length > 0)
			cmakeInputs.push(Path.join([context.compilerHome, "cmake", "haxeon-instrument.cmake"]));
		var actions = [
			new ExecutionAction(configureId, [], cmakeInputs, [Path.join([buildDirectory, "CMakeCache.txt"])], 'Configure CMake package $identity',
				Process("cmake", configureArguments, runDirectory, compilerCache)),
			new ExecutionAction(buildId, [configureId], [source], outputs, 'Build CMake target ${native.cmake.target} -> ${outputs.join(", ")}',
				Process("cmake", [
					"--build",
					buildDirectory,
					"--target",
					native.cmake.target,
					"--config",
					configuration
				], runDirectory, compilerCache), true, true, ninja)
		], artifactActions:Map<String, Array<ActionId>> = [];
		for (artifact in artifacts)
			if (artifact.id.packageId == resolvedPackage.name && artifact.id.kind == ArtifactKind.NativeSharedLibrary)
				artifactActions.set(artifact.id.key(), [buildId]);
		for (artifact in artifacts)
			if (artifact.id.packageId == resolvedPackage.name && artifact.id.kind == ArtifactKind.FfiNativeSharedLibrary) {
				var ffiName = artifact.details.get("ffi");
				if (ffiName == null)
					throw 'CMake FFI shared library ${artifact.id} is missing its FFI name';
				var imports = [
					for (candidate in resolvedPackage.ffiImports)
						if (candidate.config.name == ffiName) candidate
				];
				if (imports.length != 1)
					throw 'CMake FFI shared library ${artifact.id} refers to missing FFI import $ffiName';
				var ffi:ResolvedFfiImport = imports[0],
					sourceRelative = 'ffi/$ffiName/$ffiName-thunks.cpp',
					thunkSource = layout.ffiThunkSourcePath(resolvedPackage.name, ffiName),
					thunkObject = layout.objectPath(resolvedPackage.name, sourceRelative),
					compileId = new ActionId('native-compile:${artifact.id.key()}'),
					compileDependencies:Array<ActionId> = [],
					compileInputs = [thunkSource, ffi.header].concat(ffi.includes),
					includeDirs = resolvedPackage.includeDirs.concat(ffi.includes);
				compileDependencies.push(new ActionId('ffi-import:'
					+ new ArtifactId(resolvedPackage.name, ArtifactKind.FfiInterface, context.environment.target, ffiName).key()));
				actions.push(new ExecutionAction(compileId, compileDependencies, compileInputs, [thunkObject], 'Compile C++ $thunkSource -> $thunkObject',
					Process(toolchain.compileCommand(thunkSource), toolchain.compileArguments(thunkSource, thunkObject, includeDirs, ffi.config.standard),
						resolvedPackage.root, new Map())));
				artifactActions.set(artifact.id.key(), [compileId]);

				var ffiOutput = layout.ffiNativeLibraryPath(resolvedPackage.name, ffiName),
					linkId = new ActionId('native-link:${artifact.id.key()}'),
					linkDependencies:Array<ActionId> = [compileId],
					cmakeLinkInputs = [
						for (output in outputs)
							cmakeLinkInput(outputDirectory, output, context.environment.target.os, context.environment.target.abi)
					],
					linkInputs:Array<String> = [thunkObject].concat(cmakeLinkInputs);
				for (dependency in artifact.dependencies)
					if (dependency.kind == ArtifactKind.NativeSharedLibrary)
						linkDependencies.push(buildId);
				actions.push(new ExecutionAction(linkId, linkDependencies, linkInputs, [ffiOutput],
					'Link shared library ${resolvedPackage.name} FFI $ffiName -> $ffiOutput',
					Process(toolchain.sharedCommand(), toolchain.sharedArguments(ffiOutput, [thunkObject], cmakeLinkInputs, [outputDirectory]),
						resolvedPackage.root, new Map())));
				artifactActions.set(artifact.id.key(), [linkId]);
			}
		return {actions: actions, artifactActions: artifactActions};
	}

	/**
	 * Configure arguments for the instrumented build flavor: `cmake/haxeon-instrument.cmake` compiles the sources in the
	 * manifest's native scope with the compiler's function instrumentation (`/Gh /GH` on MSVC) and links the hooks
	 * HashLink builds; on MSVC it also gives every module a PDB. Only MSVC x64 and Linux have native instrumentation;
	 * elsewhere the flavor builds native code as usual.
	 */
	static function instrumentArguments(context:LoweringContext):Array<String> {
		var instrument = context.environment.instrument,
			target = context.environment.target;
		var msvcX64 = target.os == TargetOs.Windows && target.abi == TargetAbi.Msvc && target.arch == build.Target.TargetArch.X64;
		if (instrument == null || !(msvcX64 || target.os == TargetOs.Linux))
			return [];
		var home = context.compilerHome;
		return [
			"-DHAXEON_INSTRUMENT_HOOKS=" + Path.join([home, ".tools", "hashlink", msvcX64 ? "hlprof_penter.lib" : "libhlprof_hooks.a"]),
			"-DHAXEON_INSTRUMENT_INCLUDE=" + instrument.nativeInclude.join(";"),
			"-DHAXEON_INSTRUMENT_EXCLUDE=" + instrument.nativeExclude.join(";")
		];
	}

	/** Where a shared CMake tree leaves its runtime libraries, or null when the package has no CMake provider. */
	public static function sharedOutputDirectory(resolvedPackage:ResolvedPackage, context:LoweringContext):Null<String> {
		var native = resolvedPackage.manifest.native;
		if (native == null || native.cmake == null)
			return null;
		var source = Path.normalize(Path.join([resolvedPackage.root, native.cmake.source]));
		return Path.join([
			context.layout.sharedCMakeRoot(sharedName(source, native.cmake.target, context.environment.projectRoot)),
			"out"
		]);
	}

	/**
	 * A package's CMake tree is named after the package, so a build directory outlives a move of its source (stockkit's
	 * `core` became `native`), and CMake refuses to configure a cache that another source directory generated. The
	 * cache can only be reused by that source, so it is dropped and the configure starts the tree over.
	 */
	static function discardCacheOfOtherSource(buildDirectory:String, source:String):Void {
		var cache = Path.join([buildDirectory, "CMakeCache.txt"]);
		if (!sys.FileSystem.exists(cache))
			return;
		var generated:Null<String> = null;
		for (line in sys.io.File.getContent(cache).split("\n"))
			if (StringTools.startsWith(line, "CMAKE_HOME_DIRECTORY:")) {
				generated = StringTools.trim(line.substr(line.indexOf("=") + 1));
				break;
			}
		if (generated == null || sameDirectory(generated, source))
			return;
		sys.FileSystem.deleteFile(cache);
	}

	static function sameDirectory(first:String, second:String):Bool {
		if (Path.normalize(first) == Path.normalize(second))
			return true;
		return sys.FileSystem.exists(first) && sys.FileSystem.exists(second) && sys.FileSystem.fullPath(first) == sys.FileSystem.fullPath(second);
	}

	/** Stable directory-safe identity of a CMake source and target, relative to the workspace when possible. */
	static function sharedName(source:String, target:String, root:String):String {
		var normalizedRoot = Path.addTrailingSlash(Path.normalize(root)),
			relative = StringTools.startsWith(source, normalizedRoot) ? source.substr(normalizedRoot.length) : source,
			name = new EReg("[^A-Za-z0-9_]+", "g").replace(relative, "-");
		while (StringTools.startsWith(name, "-"))
			name = name.substr(1);
		while (StringTools.endsWith(name, "-"))
			name = name.substr(0, name.length - 1);
		return name + "--" + target;
	}

	static final ninjaVersions = new Map<String, String>();

	/** The pinned Ninja under `.tools` when bootstrapped, otherwise whatever `ninja` resolves to on PATH. */
	public static function ninjaExecutable(home:String):String {
		var pinned = Path.join([home, ".tools", "ninja", "ninja"]);
		return sys.FileSystem.exists(pinned) ? pinned : "ninja";
	}

	/** Output of `ninja --version`, or null when the executable cannot run. */
	static function ninjaVersion(executable:String):Null<String> {
		if (!ninjaVersions.exists(executable)) {
			var output = HostCommand.text(executable, ["--version"]);
			ninjaVersions.set(executable, output == null ? "" : output);
		}
		var version = ninjaVersions.get(executable);
		return version == "" ? null : version;
	}

	/** Ninja 1.13 added the GNU jobserver client, which lets it share Haxeon's token pool. */
	public static function ninjaSupportsJobserver(executable:String):Bool {
		var version = ninjaVersion(executable);
		if (version == null)
			return false;
		var parts = version.split("."),
			major = Std.parseInt(parts[0]),
			minor = parts.length > 1 ? Std.parseInt(parts[1]) : 0;
		return major != null && minor != null && (major > 1 || (major == 1 && minor >= 13));
	}

	/**
	 * Ninja builds in parallel by default, while `cmake --build` on the Makefiles generator is serial
	 * without `-j`. On Windows the Visual Studio generator compiles a project's files one at a time and checks every
	 * project again when nothing changed, so MSVC builds use Ninja too, in the developer environment that
	 * `MsvcEnvironment` provides; the Ninja that Visual Studio ships is on its PATH.
	 * `HAXEON_CMAKE_GENERATOR=default` keeps the platform's default generator.
	 */
	static function ninjaAvailable(target:Target, home:String):Bool {
		if (Sys.getEnv("HAXEON_CMAKE_GENERATOR") == "default")
			return false;
		if (target.os == TargetOs.Windows
			&& (target.abi != TargetAbi.Msvc || Sys.systemName() != "Windows" || !MsvcEnvironment.ensure(target.arch)))
			return false;
		return ninjaVersion(ninjaExecutable(home)) != null;
	}

	static function cmakeLinkInput(outputDirectory:String, output:String, os:TargetOs, abi:TargetAbi):String {
		if (os != TargetOs.Windows)
			return output;
		var baseName = Path.withoutExtension(Path.withoutDirectory(output));
		return switch abi {
			case TargetAbi.Msvc: Path.join([outputDirectory, baseName + ".lib"]);
			case TargetAbi.Gnu: Path.join([outputDirectory, "lib" + baseName + ".dll.a"]);
			case _: output;
		};
	}
}
