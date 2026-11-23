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
import tools.LiveHostBuild;

/**
 * `haxeon dev package [--output=DIR] [--version=VERSION] [--no-archive]`: stages this checkout's release for the platform it runs
 * on, `DIR/haxeon-VERSION-PLATFORM/` (`DIR` is `out/release` by default), and archives it beside, as `.tar.gz` or, on Windows,
 * `.zip` (docs/reference/RELEASES.md). The release is Haxeon's SDK (docs/design/SDK_LAYOUT.md), made in three steps:
 *
 * - the install: a copy of the checkout's out/sdk as its native build staged it (CMakeLists.txt, `haxeon-sdk`), which is the one
 *   definition of the layout, without what a release has of its own (its manifest and registry) and without the leftovers of
 *   publishing by rename;
 * - the named roots materialized: the standard library, the templates, and the registry, each first-party package published from
 *   the checkout's at its version (`publishRegistry`), at the relative roots the release's manifest names;
 * - what only a release has: the programs a checkout builds from the compiler's sources when a command needs them, prebuilt and
 *   stamped with the sources' digest (`AotCompiler.shipped`: the compiler's bytecode, with the pinned Haxe as the CLI builds the
 *   compiler in a checkout, and both flavors of the live development host, `LiveHostBuild`), LICENSE, NOTICE and README.md, and
 *   the manifest, which records that digest and names no `source`, which makes the directory a release (`build.HaxeonSdk`).
 *
 * The compiler built ahead of time is in the install when `haxeon dev aot` built it from these sources; a stale one is an error,
 * as the release would never run it. The compiler's sources stay behind: every stamp must hold the digest the manifest records.
 */
class ReleasePackage {
	/** Files that publishing by rename leaves beside a program a process still ran (cmake/haxeon-replace.cmake, haxeon-publish.cmake). */
	static final PUBLISHING_LEFTOVER = ~/\.(new|old|replaced)-[0-9a-z]+$/;

	/** The jobs the live hosts' builds run, as a build's default. */
	static inline final BUILD_JOBS = 4;

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
			digest = AotCompiler.sourcesDigest(sdk, compilerSource);
		if (!FileSystem.exists(HashLinkPath.executable(sdk))
			|| !FileSystem.exists(HashLinkPath.executable(sdk, "haxeon")))
			throw new InternalError('Missing ${HashLinkPath.executable(sdk, "haxeon")}: build the native runtime first (haxeon dev native)');
		if (FileSystem.exists(native) && AotCompiler.current(sdk) == null)
			throw new InternalError('$native is stale: rebuild it with "haxeon dev aot", or remove it to package without it');
		var shipped = [
			{
				name: AotCompiler.BYTECODE,
				path: new ToolArtifacts(home).resolve({main: "tools.CompilerExecutable", classPaths: [], defines: []})
			}
		];
		for (instrument in [false, true])
			shipped.push({name: LiveHostBuild.name(instrument),
				path: LiveHostBuild.build(sdk, BUILD_JOBS, instrument)});

		var name = 'haxeon-$version-${platform()}', root = Path.join([output, name]);
		cmake(home, ["-E", "rm", "-rf", root]);
		cmake(home, ["-E", "make_directory", root]);
		// The install.
		for (entry in FileSystem.readDirectory(sdk))
			if (entry != HaxeonSdk.MANIFEST && entry != "registry")
				cmake(home, [
					"-E",
					FileSystem.isDirectory(Path.join([sdk, entry])) ? "copy_directory" : "copy",
					Path.join([sdk, entry]),
					Path.join([root, entry])
				]);
		var bin = Path.join([root, Path.withoutDirectory(HashLinkPath.directory(sdk))]);
		for (entry in FileSystem.readDirectory(bin))
			if (PUBLISHING_LEFTOVER.match(entry))
				FileSystem.deleteFile(Path.join([bin, entry]));
		// The roots the checkout's SDK names, materialized in the release.
		cmake(home, ["-E", "copy_directory", HaxeonSdk.stdlib(sdk), Path.join([root, "stdlib"])]);
		cmake(home, ["-E", "copy_directory", HaxeonSdk.templates(sdk), Path.join([root, "templates"])]);
		publishRegistry(sdk, Path.join([root, "registry"]));
		// What only a release has; the manifest is written last.
		for (program in shipped) {
			// A new file, not one with the build's own mode: a compiler's output is private to its user.
			File.copy(program.path, Path.join([bin, program.name]));
			File.saveContent(AotCompiler.stampOf(Path.join([bin, program.name])), digest + "\n");
		}
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
