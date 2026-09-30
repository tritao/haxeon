package build.native;

import build.Artifact;
import build.Artifact.ArtifactKind;
import build.ArtifactId;
import build.BuildEnvironment.BuildProfile;
import build.lowering.LoweringContext;
import build.execution.ActionId;
import build.execution.ExecutionAction;
import build.execution.ExecutionAction.ActionKind;
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
			ninja = ninjaAvailable(context.environment.target.os, context.compilerHome),
			ninjaProgram = ninjaExecutable(context.compilerHome), // CMake rejects a cache created by another generator, so Ninja trees get their own directory.
			buildTree = ninja ? "cmake-ninja" : "cmake", // Workspace builds identify a CMake tree by what it builds, so packages that request the same
		// (source, target) pair share one configure, one build and one set of runtime libraries.
			shared = context.sharedNative,
			identity = shared ? sharedName(source, native.cmake.target, context.environment.projectRoot) : resolvedPackage.name,
			sharedRoot = shared ? layout.sharedCMakeRoot(identity) : null,
			buildDirectory = shared ? Path.join([sharedRoot, buildTree]) : Path.join([layout.packageRoot(resolvedPackage.name), buildTree]),
			output = shared ? (native.cmake.library == null ? Path.join([sharedRoot, "out", native.cmake.target]) : Path.join([
				sharedRoot,
				"out",
				(context.environment.target.os == TargetOs.Windows ? "" : "lib") + native.cmake.library + context.environment.toolchain.sharedLibrarySuffix
			])) : (native.cmake.library == null ? layout.haxeonNativeLibraryPath(resolvedPackage.name) : layout.cmakeSharedLibraryPath(resolvedPackage.name,
				native.cmake.library)),
			outputDirectory = Path.directory(output),
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
			configureId = new ActionId('native-cmake-configure:$identity:${context.environment.target.toString()}'),
			buildId = new ActionId('native-cmake-build:$identity:${context.environment.target.toString()}'),
			toolchain = new NativeToolchain(context.environment);
		if (native.cmake.library != null) {
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
		var actions = [
			new ExecutionAction(configureId, [], cmakeInputs, [Path.join([buildDirectory, "CMakeCache.txt"])], 'Configure CMake package $identity',
				Process("cmake", configureArguments, runDirectory, new Map())),
			new ExecutionAction(buildId, [configureId], [source], [output], 'Build CMake target ${native.cmake.target} -> $output', Process("cmake", [
				"--build",
				buildDirectory,
				"--target",
				native.cmake.target,
				"--config",
				configuration
			], runDirectory, new Map()), true, true, ninja)
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
					cmakeLinkInput = cmakeLinkInput(outputDirectory, output, context.environment.target.os, context.environment.target.abi),
					linkInputs:Array<String> = [thunkObject, cmakeLinkInput];
				for (dependency in artifact.dependencies)
					if (dependency.kind == ArtifactKind.NativeSharedLibrary)
						linkDependencies.push(buildId);
				actions.push(new ExecutionAction(linkId, linkDependencies, linkInputs, [ffiOutput],
					'Link shared library ${resolvedPackage.name} FFI $ffiName -> $ffiOutput',
					Process(toolchain.sharedCommand(), toolchain.sharedArguments(ffiOutput, [thunkObject], [cmakeLinkInput], [outputDirectory]),
						resolvedPackage.root, new Map())));
				artifactActions.set(artifact.id.key(), [linkId]);
			}
		return {actions: actions, artifactActions: artifactActions};
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
		if (!ninjaVersions.exists(executable))
			ninjaVersions.set(executable, try {
				var process = new sys.io.Process(executable, ["--version"]),
					output = StringTools.trim(process.stdout.readAll().toString()),
					status = process.exitCode();
				process.close();
				status == 0 ? output : "";
			} catch (_:Dynamic) "");
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
	 * without `-j`. Windows keeps its default generator so MSVC does not need a prepared environment.
	 */
	static function ninjaAvailable(os:TargetOs, home:String):Bool {
		if (os == TargetOs.Windows || Sys.getEnv("HAXEON_CMAKE_GENERATOR") == "default")
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
