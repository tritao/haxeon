package compiler.tools;

import compiler.Compiler;
import compiler.backend.Backend.BackendTarget;
import compiler.backend.BackendTargets;
import compiler.compilation.BackendArtifact.HlArtifact;
import compiler.core.FileVersion;
import compiler.core.InternalError;
import compiler.ffi.FfiRegistry.FfiConfiguration;
import compiler.ffi.FfiRegistry.FfiInterfaceSource;
import compiler.ffi.FfiRegistry.FfiProjectionSource;
import compiler.ffi.HxiInterfaceOrder;
import compiler.hl.HlWriter;
import compiler.modules.CodeIdentityTable;
import compiler.modules.ModulePath;
import compiler.runtime.CompilerIntrinsics;
import compiler.tools.CompilerRequest.CompileSessionMode;
import haxe.Json;
import haxe.io.Bytes;
import haxe.io.Path;
import runtime.LiveRefusal;
import sys.FileSystem;
import sys.io.File;

/** One reusable semantic compiler, reset whenever its source/FFI configuration changes. */
class CompilerSession {
	var compiler:Null<Compiler>;
	var configuration:Null<String>;
	var unrecordedPublication:Null<{output:String, marker:String}>;
	var requestSources:Map<String, String> = [];

	/**
	 * Each source file's text as the session last read it, with the file's version then (`FileVersion`): a request whose file
	 * still has that version takes the text without reading the file. A version is trusted once a later request has read the
	 * file at it again, so a write that left the version as it was (the same size, within the file system's timestamp
	 * resolution of the read) is read by that later request.
	 */
	var sourceReads:Map<String, {version:Bytes, text:String, settled:Bool}> = [];

	/**
	 * The build of the compiler its live history is keyed by: the running program's fingerprint
	 * (`CodeIdentityTable.compilerVersion`) unless one is given.
	 */
	final compilerBuild:Null<String>;

	public function new(?compilerBuild:String)
		this.compilerBuild = compilerBuild;

	/**
	 * The digest of the identity state this session last wrote (`writeBaseline`). A `baseline` request naming exactly that state
	 * builds on the session, which holds it; any other baseline starts the session over from the file.
	 */
	var writtenBaseline:Null<String>;

	/** The `.functions` map of the module last written (`CompilerDriver.functionMap`). */
	public var functionMap = new IndexText();

	public function reset():Void {
		compiler = null;
		writtenBaseline = null;
		unrecordedPublication = null;
		configuration = null;
		encodedModule = null;
		functionMap = new IndexText();
		sourceReads = [];
	}

	/**
	 * The bytes of the module last written, with their build id, which a build that reuses the module (see `PipelineSnapshot`)
	 * takes without digesting the bytes again. Only the bytes: the module's object form is the build's, not the session's.
	 */
	var encodedModule:Null<{bytes:haxeon.io.SegmentedBytes, buildId:String}>;

	/** The build id of `artifact`'s module: the SHA-256 of the bytes `writeHashLink` writes, worked out once for them. */
	public function hashLinkBuildId(artifact:HlArtifact):String {
		var known = encodedModule;
		if (known == null || known.bytes != artifact.sections) {
			known = {
				bytes: artifact.sections,
				buildId: build.execution.ContentDigest.makeHex(artifact.sections.flatten())
			};
			encodedModule = known;
		}
		return known.buildId;
	}

	public function writeHashLink(artifact:HlArtifact, path:String):Void
		HlWriter.saveSegments(artifact.sections, path);

	/** Wasm guests import their host services through this interface of the standard library at `stdlib`. */
	static function hostInterfaces(target:Null<BackendTarget>, stdlib:String):{
		interfaces:Array<String>,
		projections:Array<String>
	} return switch target {
		case Wasm32 | WasmGc: {
			interfaces: [
				Path.join([stdlib, "haxeon/wasm/HaxeonHost.hxi"]),
				Path.join([stdlib, "haxeon/wasm/HaxeonCrypto.hxi"])
			],
			projections: [
				Path.join([stdlib, "haxeon/wasm/HaxeonHost.hxmap"]),
				Path.join([stdlib, "haxeon/wasm/HaxeonCrypto.hxmap"])
			]
		};
		case _: {interfaces: [], projections: []};
	};

	/**
	 * Stdlib modules a Wasm host calls into, compiled into every guest that shares linear memory with its host
	 * (haxeon.wasm.HostError reads its message from that memory): wasm32 always, wasm-gc when it imports memory.
	 */
	static function hostSources(request:CompilerRequest):Array<String>
		return switch BackendTargets.parse(request.target) {
			case Wasm32: [Path.join([request.stdlib, "haxeon/wasm/HostError.hx"])];
			case WasmGc if (request.importMemory == true): [Path.join([request.stdlib, "haxeon/wasm/HostError.hx"])];
			case _: [];
		};

	public function prepare(request:CompilerRequest, report:String->Void):Compiler {
		// A fresh request owes nothing to the requests before it.
		if (request.session == CompileSessionMode.Fresh)
			reset();
		// A baseline the session did not write (one a device rejected an edit from, say) is where the module now is.
		var baseline = request.baseline;
		if (baseline != null && writtenBaseline != digest(File.getBytes(baseline)))
			reset();
		// This compile moves the session past whatever it wrote; only writing the state again names it.
		writtenBaseline = null;
		// Every consumer of a source in this request sees the same bytes.
		requestSources = [];
		var host = hostInterfaces(BackendTargets.parse(request.target), request.stdlib),
			interfacePaths = request.ffiInterfaces.concat(host.interfaces),
			projectionPaths = request.ffiProjections.concat(host.projections);
		var interfaces:Array<FfiInterfaceSource> = [for (path in interfacePaths) {
			path: path, text: read(path)
		}],
			projections:Array<FfiProjectionSource> = [for (path in projectionPaths) {
				path: path, text: read(path)
			}],
			identity = Json.stringify({
				target: request.target,
				buildMode: request.buildMode,
				exports: request.exports,
				live: request.live,
				importMemory: request.importMemory,
				sharedMemory: request.sharedMemory == true,
				entry: request.entry,
				defines: request.defines,
				// Another set of passes or checks is another session: caches (inlining, pipeline, lowering) hold their results.
				options: request.options.key(),
				roots: request.roots,
				stdlib: request.stdlib,
				packageRoots: request.packageRoots,
				paths: request.paths,
				interfaces: interfaces,
				projections: projections
			});
		if (configuration != identity)
			reset();
		if (compiler == null) {
			interfaces = [for (path in interfacePaths) {
				path: path, text: read(path)
			}];
			projections = [for (path in projectionPaths) {
				path: path, text: read(path)
			}];
		}
		// A module resolved lazily (notably stdlib) has an absolute source path; one whose file is gone takes a new session, which
		// resolves its imports again. An edited one is refreshed below, as the manifest's sources are.
		if (compiler != null)
			for (state in compiler.modules) {
				var path = state.source.path;
				if (Path.isAbsolute(path) && !FileSystem.exists(path)) {
					reset();
					break;
				}
			}
		// The request reads its sources before it calls `report`: a write after that point belongs to the next request.
		var existing = compiler;
		if (existing != null) {
			for (path in request.paths)
				read(path);
			for (state in existing.modules)
				if (Path.isAbsolute(state.source.path))
					read(state.source.path);
		}
		if (request.live)
			takeBackRefusedRevisions(request, report);
		// `report` is caller code, so nothing proved about the field survives a call to it; a local does.
		existing = compiler;
		if (existing == null) {
			var resumed = baseline != null ? resumeBaseline(baseline, interfaces, projections,
				report) : request.live ? resumeLiveModule(request, identity, interfaces, projections, report) : null;
			var created = resumed == null ? new Compiler() : resumed;
			compiler = created;
			if (resumed == null) {
				compiler.enablePublicationTracking();
				CompilerIntrinsics.register(compiler);
			}
			var defines = request.defines.concat(CompilerDriver.targetDefines(request.target));
			compiler.configure("cli:" + request.target + ":" + defines.join("|"), "cli:" + request.target, defines);
			compiler.options = request.options;
			if (resumed == null) {
				for (source in projections) {
					if (request.verbosity.atLeast(Verbosity.Detailed))
						report("loading FFI projection " + source.path);
					compiler.addFfiProjection(source.path, source.text);
				}
				for (source in HxiInterfaceOrder.dependenciesFirst(interfaces)) {
					if (request.verbosity.atLeast(Verbosity.Detailed))
						report("loading FFI interface " + source.path);
					compiler.addFfiInterface(source.path, source.text);
				}
			}
			compiler.addStandardLibrarySourceRoot(request.stdlib);
			for (root in request.roots)
				compiler.addSourceRoot(root);
			for (root in request.packageRoots)
				compiler.addPackageSourceRoot(root.packageName, root.path);
			configuration = identity;
		} else {
			if (request.verbosity.atLeast(Verbosity.Normal))
				report("reusing compiler session");
			for (name => state in existing.modules) {
				var path = state.source.path;
				if (Path.isAbsolute(path)) {
					var changed = readChanged(path);
					if (changed != null)
						existing.refreshLoadedSource(name, changed);
				}
			}
		}
		SourceManifestLoader.load(compiler, request.roots, request.paths, request.packageRoots, readChanged);
		// Wasm guests always carry the stdlib modules their host calls into.
		var hostModules = hostSources(request);
		SourceManifestLoader.load(compiler, [request.stdlib], hostModules, null, readChanged);
		for (path in hostModules)
			compiler.addRootModule(ModulePath.fromFile(SourceManifestLoader.projectPath(path, [request.stdlib])));
		compiler.setExportedFunctions(request.exports);
		return compiler;
	}

	/**
	 * The live host writes `<output>.live.refused` (`runtime.LiveRefusal`) when `--strict-live` refuses a revision. The app
	 * keeps running the older revision, so a patch built on the refused one could never apply, and neither could any after
	 * it. The compiler takes the refused revisions back before it reads the sources, and this build patches the revision
	 * the app runs, with the refused edits in it again.
	 */
	function takeBackRefusedRevisions(request:CompilerRequest, report:String->Void):Void {
		var active = compiler;
		if (active == null)
			return;
		var published = request.publishedOutput == null ? request.output : request.publishedOutput,
			path = LiveRefusal.path(published);
		if (!FileSystem.exists(path))
			return;
		var text = try File.getContent(path) catch (_:Dynamic) null;
		try
			FileSystem.deleteFile(path)
		catch (_:Dynamic) {}
		var marker = try File.getContent(published + ".live.full") catch (_:Dynamic) null;
		if (text == null || marker == null)
			return;
		var record = LiveRefusal.parse(text);
		if (record == null || record.identity != marker.substring(0, marker.lastIndexOf(":")))
			return;
		if (active.retractPublication(record.running)) {
			// The published marker still names the refused revision, which the retracted history no longer describes.
			unrecordedPublication = null;
			report('live host refused revision ${record.refused}; patching from revision ${record.running}, which it runs');
		} else
			report('live host runs revision ${record.running}, which this compiler no longer holds; restart the live session to patch again');
	}

	/** A compiler resumed from the identity state at `path`, as the module built from it left it. */
	function resumeBaseline(path:String, interfaces:Array<FfiInterfaceSource>, projections:Array<FfiProjectionSource>,
			report:String->Void):Compiler {
		report("compiling against the baseline " + path);
		return new Compiler(File.getBytes(path), CompilerIntrinsics.configuration(),
			new FfiConfiguration(interfaces, projections));
	}

	/** Writes the session's identity state to `path`: the baseline a later request compiles against (`CompilerRequest.baseline`). */
	public function writeBaseline(path:String):Void {
		var active = compiler;
		if (active == null)
			throw new InternalError("No compiler to write a baseline from");
		var state = active.exportIdentityState();
		File.saveBytes(path, state);
		writtenBaseline = digest(state);
	}

	static function digest(bytes:Bytes):String
		return build.execution.ContentDigest.makeHex(bytes);

	/** Notes a live publication whose history `recordLiveState` writes once the session is idle. */
	public function recordLivePublication(output:String, marker:String):Void
		unrecordedPublication = {output: output, marker: marker};

	/**
	 * Records the history the last live revision was assembled from beside the module it published (`<output>.live.state`),
	 * keyed by that publication's `.live.full` marker, this session's configuration and the compiler build. A later
	 * session, such as the compile server started after the editor restarts, resumes it and patches the module the app is
	 * running instead of assembling a new module whose identity forces a reload. Encoding the history of an app takes
	 * seconds, so the server calls this between requests rather than on an edit's path. True when it wrote the history.
	 */
	public function recordLiveState():Bool {
		var publication = unrecordedPublication,
			current = configuration,
			active = compiler;
		unrecordedPublication = null;
		if (publication == null || current == null || active == null)
			return false;
		var output = publication.output;
		// A module published since (by another compiler) is not the one this history describes.
		if (!FileSystem.exists(output + ".live.full") || File.getContent(output + ".live.full") != publication.marker)
			return false;
		var key = Bytes.ofString(liveStateKey(publication.marker, current) + "\n"),
			state = active.exportIdentityState(),
			bytes = Bytes.alloc(key.length + state.length);
		bytes.blit(0, key, 0, key.length);
		bytes.blit(key.length, state, 0, state.length);
		var temporary = output + ".live.state.tmp." + Std.string(Std.random(0x3fffffff));
		try {
			File.saveBytes(temporary, bytes);
			// A different compiler can finish publishing while this one encodes its history.
			if (File.getContent(output + ".live.full") != publication.marker) {
				FileSystem.deleteFile(temporary);
				return false;
			}
			CompilerDriver.replaceFile(temporary, output + ".live.state");
		} catch (error:haxe.Exception) {
			if (FileSystem.exists(temporary))
				FileSystem.deleteFile(temporary);
			throw error;
		}
		return true;
	}

	public function hasUnrecordedLiveState():Bool
		return unrecordedPublication != null;

	/**
	 * The compiler that published the module now at the request's output, when its recorded history is for exactly that
	 * module (the whole module is on disk, its `.live.full` marker names the recorded revision) under this configuration
	 * and compiler. Anything else (no history, a stale or partial module, another compiler) starts a new module.
	 */
	function resumeLiveModule(request:CompilerRequest, identity:String, interfaces:Array<FfiInterfaceSource>,
			projections:Array<FfiProjectionSource>,
			report:String->Void):Null<Compiler> {
		var published = request.publishedOutput == null ? request.output : request.publishedOutput;
		if (published == null || !FileSystem.exists(published + ".live.full")
			|| !FileSystem.exists(published + ".live.state"))
			return null;
		try {
			var key = liveStateKey(File.getContent(published + ".live.full"), identity),
				bytes = File.getBytes(published + ".live.state"),
				separator = -1;
			for (index in 0...bytes.length)
				if (bytes.get(index) == "\n".code) {
					separator = index;
					break;
				}
			if (separator < 0 || bytes.getString(0, separator) != key) {
				report("live history does not match the published module; starting a new module");
				return null;
			}
			var resumed = new Compiler(bytes.sub(separator + 1, bytes.length - separator - 1),
				CompilerIntrinsics.configuration(),
				new FfiConfiguration(interfaces, projections));
			report("resuming the published live module " + File.getContent(published + ".live.full"));
			return resumed;
		} catch (error:Dynamic) {
			report("live history could not be resumed (" + Std.string(error) + "); starting a new module");
			return null;
		}
	}

	/**
	 * The key of the history recorded for the module `marker` names under `configuration`. It names the compiler's build, not
	 * its program's path: history is the functions, slots and stable ids that build lowered the module to, and another build
	 * at the same path (a compile server rebuilt in place) lowers the unchanged functions differently, so it must not patch
	 * on top of them.
	 */
	function liveStateKey(marker:String, configuration:String):String {
		var program = compilerBuild;
		if (program == null)
			program = CodeIdentityTable.compilerVersion();
		return marker + " " + build.execution.ContentDigest.makeHex(Bytes.ofString(configuration + "\n" + program));
	}

	function read(path:String):String {
		// fullPath is null for a path that does not exist (a source list that names a deleted file).
		var key = FileSystem.fullPath(path);
		if (key == null)
			throw new InternalError('Source file does not exist: $path');
		var cached = requestSources.get(key);
		if (cached != null)
			return cached;
		var known = sourceReads.get(key), text:String;
		var current = known != null && known.settled ? FileVersion.of(key) : null;
		if (known != null && current != null && current.compare(known.version) == 0)
			text = known.text;
		else {
			var read = FileVersion.readVersionedSource(key);
			// The same text keeps the String the modules hold, which they then find unchanged without reading it.
			text = known != null && known.text == read.text ? known.text : read.text;
			sourceReads.set(key, {
				version: read.version,
				text: text,
				settled: known != null && known.version.compare(read.version) == 0
			});
		}
		requestSources.set(key, text);
		return text;
	}

	function readChanged(path:String):Null<String>
		return read(path);
}
