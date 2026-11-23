package tools.dev;

import build.AotCompiler;
import build.HashLinkPath;
import build.HaxeonSdk;
import build.execution.ProcessRunner;
import compiler.core.InternalError;
import haxe.io.Path;
import project.PackageManifest;
import project.PackageResolver;
import project.RegistryIndex;
import project.RegistryPublisher;
import project.RegistrySourceAcquirer;
import project.SourceCache;
import sys.FileSystem;
import sys.io.File;

/**
 * `haxeon dev package [--output=DIR] [--version=VERSION] [--no-archive]`: stages this checkout's release for the platform it runs
 * on, `DIR/haxeon-VERSION-PLATFORM/` (`DIR` is `out/release` by default), and archives it beside, as `.tar.gz` or, on Windows,
 * `.zip` (docs/reference/RELEASES.md). The release is Haxeon's SDK (docs/design/SDK_LAYOUT.md): the native build's out/sdk, with
 * the standard library and templates copied in and its own manifest:
 *
 *   haxeon-sdk.toml                 the manifest: version, commit, platform, the compiler sources' digest and the roots below,
 *                                   and no `source`, which makes the directory a release (`build.HaxeonSdk`)
 *   bin/                            the VM's directory: hl, haxeon, the CLI's bytecode (haxeon-cli.hl), the CLI and compiler built
 *                                   ahead of time with its stamp (and its .pdb with MSVC) when it is built and current, the
 *                                   compiler's bytecode with its stamp, and the shared libraries beside the VM
 *   stdlib/                         the standard library
 *   templates/                      the project templates of `haxeon create` (templates/README.md)
 *   registry/                       the haxeon registry: index.json and each first-party package at NAME/VERSION/, published
 *                                   from the checkout's (`publishRegistry`)
 *   lib/<target>/, include/, src/, cmake/
 *                                   the SDK's libraries, headers, entry points and CMake package (`find_package(Haxeon)`)
 *   LICENSE, NOTICE, README.md
 *
 * It builds what a checkout's native build does not, the compiler's bytecode: `tools.CompilerExecutable` with the pinned Haxe, as the
 * CLI builds the compiler in a checkout, stamped with the sources' digest (`AotCompiler.bytecode`). It packages the compiler built
 * ahead of time when `haxeon dev aot` built it from these sources, and goes without it when there is none; a stale one is
 * an error, as the release would never run it. The compiler's sources stay behind: the marker records their digest, which the
 * stamps must hold.
 */
class ReleasePackage {
	public static function run(arguments:Array<String>, home:String):Int {
		home = Path.normalize(home);
		var output = Path.join([home, "out", "release"]),
			version = project.PackageCompatibility.CURRENT_HAXEON,
			archive = true;
		for (argument in arguments)
			if (StringTools.startsWith(argument, "--output="))
				output = absolute(argument.substr("--output=".length));
			else if (StringTools.startsWith(argument, "--version="))
				version = argument.substr("--version=".length);
			else if (argument == "--no-archive")
				archive = false;
			else
				throw new InternalError('Usage: haxeon dev package [--output=DIR] [--version=VERSION] [--no-archive] (unexpected "$argument")');
		if (version == "" || ~/[\/\\\s]/.match(version))
			throw new InternalError('Not a release version: "$version"');

		var sdk = HaxeonSdk.ofCheckout(home),
			compilerSource = AotCompiler.sources(sdk),
			native = AotCompiler.executable(sdk),
			digest = AotCompiler.sourcesDigest(sdk, compilerSource),
			bytecode = new ToolArtifacts(home).resolve({main: "tools.CompilerExecutable", classPaths: [], defines: []});

		if (FileSystem.exists(native) && AotCompiler.current(sdk) == null)
			throw new InternalError('$native is stale: rebuild it with "haxeon dev aot", or remove it to package without it');

		var name = 'haxeon-$version-${platform()}', root = Path.join([output, name]);
		var bin = Path.join([root, "bin"]);
		cmake(home, ["-E", "rm", "-rf", root]);
		cmake(home, ["-E", "make_directory", bin]);
		var vm = HashLinkPath.directory(sdk), suffix = Sys.systemName() == "Windows" ? ".exe" : "";
		var programs = ['hl$suffix', 'haxeon$suffix', "haxeon-cli.hl"];
		if (FileSystem.exists(native))
			programs = programs.concat([Path.withoutDirectory(native), Path.withoutDirectory(AotCompiler.stamp(sdk))]);
		// An MSVC build's debug information, which its stack traces read, is beside it.
		var symbols = Path.withoutExtension(native) + ".pdb";
		if (FileSystem.exists(native) && FileSystem.exists(symbols))
			programs.push(Path.withoutDirectory(symbols));
		for (entry in FileSystem.readDirectory(vm))
			if (~/\.(dll|hdll|dylib|so)(\.[0-9.]+)?$/.match(entry))
				programs.push(entry);
		for (program in programs) {
			var path = Path.join([vm, program]);
			if (!FileSystem.exists(path))
				throw new InternalError('Missing $path: build the native runtime first (haxeon dev native)');
			cmake(home, ["-E", "copy", path, bin]);
		}
		// Under the names `AotCompiler` looks for beside the release's VM.
		var bytecodeName = Path.withoutDirectory(AotCompiler.bytecode(sdk));
		cmake(home, ["-E", "copy", bytecode, Path.join([bin, bytecodeName])]);
		File.saveContent(Path.join([bin, Path.withoutDirectory(AotCompiler.bytecodeStamp(sdk))]), digest + "\n");
		// The roots the checkout's SDK names, materialized in the release.
		cmake(home, ["-E", "copy_directory", HaxeonSdk.stdlib(sdk), Path.join([root, "stdlib"])]);
		cmake(home, ["-E", "copy_directory", HaxeonSdk.templates(sdk), Path.join([root, "templates"])]);
		publishRegistry(sdk, Path.join([root, "registry"]));
		// The rest of the SDK as the native build staged it; the manifest is the release's own, written last.
		for (part in ["lib", "include", "src", "cmake"])
			cmake(home, ["-E", "copy_directory", Path.join([sdk, part]), Path.join([root, part])]);
		// The stamps hold the digest of what the release holds: no source changed while it was made.
		if (AotCompiler.sourcesDigest(sdk, compilerSource) != digest)
			throw new InternalError("The compiler sources changed while the release was made; run it again");
		for (file in ["LICENSE", "NOTICE", "README.md"])
			if (FileSystem.exists(Path.join([home, file])))
				cmake(home, ["-E", "copy", Path.join([home, file]), root]);
		var commit = ProcessRunner.capture("git", ["-C", home, "rev-parse", "--short=12", "HEAD"]);
		File.saveContent(Path.join([root, HaxeonSdk.MANIFEST]),
			HaxeonSdk.releaseManifest(version, commit.status == 0 ? StringTools.trim(commit.output) : "unknown",
			platform(), digest));
		Sys.println('Staged $root' + (FileSystem.exists(native)
			? "" : ' (without $native: run "haxeon dev aot" first to include it)'));
		if (!archive)
			return 0;
		var file = name + (Sys.systemName() == "Windows" ? ".zip" : ".tar.gz");
		if (FileSystem.exists(Path.join([output, file])))
			FileSystem.deleteFile(Path.join([output, file]));
		var format = Sys.systemName() == "Windows" ? ["cf", file, "--format=zip"] : ["czf", file],
			status = ProcessRunner.run("cmake", ["-E", "tar"].concat(format).concat([name]), output, new Map());
		if (status != 0)
			return status;
		Sys.println('Archived ${Path.join([output, file])}');
		return 0;
	}

	/**
	 * The release's haxeon registry: each package of the checkout's (out/sdk/registry, which resolves them live) published at its
	 * version, its path dependencies on the others as version ranges. Each is then resolved from the release's registry alone,
	 * which checks that what was published is a whole package graph.
	 */
	static function publishRegistry(home:String, registry:String):Void {
		var checkout = HaxeonSdk.registryRoot(home), index = checkout == null ? null : RegistryIndex.load(checkout);
		if (index == null)
			throw new InternalError('This checkout has no haxeon registry at $checkout: build it with scripts/build-native.sh');
		var packages = index.liveDirectories(), names = [for (name in index.packages.keys()) name];
		names.sort(Reflect.compare);
		var published:Array<String> = [];
		for (name in names) {
			var live = index.live(name);
			if (live == null)
				throw new InternalError('The checkout\'s haxeon registry has "$name" without a package directory');
			var manifest = PackageManifest.find(live.path);
			if (manifest == null)
				throw new InternalError('The checkout\'s haxeon registry has "$name" without a package directory');
			RegistryPublisher.publish(manifest, registry, name, live.version, packages);
			published.push(Path.join([registry, name, live.version, Path.withoutDirectory(manifest)]));
		}
		var resolver = new PackageResolver(new RegistrySourceAcquirer(SourceCache.registryRoot(), registry));
		for (manifest in published)
			resolver.resolve(manifest);
		Sys.println('Published ${names.length} packages into the release\'s haxeon registry: ${names.join(", ")}');
	}

	/** The release's platform name: the operating system and the processor, as `linux-x86_64` or `windows-arm64`. */
	public static function platform():String {
		var system = switch Sys.systemName() {
			case "Windows": "windows";
			case "Mac": "macos";
			case _: "linux";
		};
		var machine = Sys.systemName() == "Windows"
			? Sys.getEnv("PROCESSOR_ARCHITECTURE") : StringTools.trim(ProcessRunner.capture("uname",
			["-m"]).output);
		var processor = switch machine == null ? "" : machine.toLowerCase() {
			case "amd64", "x86_64", "x64": "x86_64";
			case "arm64", "aarch64": "arm64";
			case other: throw new InternalError('Unknown processor "$other"');
		};
		return '$system-$processor';
	}

	static function absolute(path:String):String
		return Path.normalize(Path.isAbsolute(path) ? path : Path.join([Sys.getCwd(), path]));

	static function cmake(home:String, arguments:Array<String>):Void {
		var status = ProcessRunner.run("cmake", arguments, home, new Map());
		if (status != 0)
			throw new InternalError('cmake ${arguments.join(" ")} failed (exit $status)');
	}
}
