package compiler.tools;

import compiler.Compiler;
import compiler.Compiler.FfiConfiguration;
import compiler.Compiler.FfiInterfaceSource;
import compiler.Compiler.FfiProjectionSource;
import compiler.ffi.HxiInterfaceOrder;
import compiler.modules.ModulePath;
import compiler.runtime.CompilerIntrinsics;
import compiler.hl.HlCode;
import compiler.hl.HlWriter;
import compiler.hl.HlWriterCache;
import compiler.Source.SourceFile;
import compiler.syntax.Lexer;
import compiler.syntax.Token.TokenKind;
import haxe.Json;
import haxe.io.Bytes;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;

/** One reusable semantic compiler, reset whenever its source/FFI configuration changes. */
class CompilerSession {
	var compiler:Null<Compiler>;
	var configuration:Null<String>;
	var writerCache = new HlWriterCache();
	var sourceTexts:Map<String, String> = [];
	var unrecordedPublication:Null<{output:String, marker:String}>;

	public function new() {}

	public function reset():Void {
		compiler = null;
		unrecordedPublication = null;
		configuration = null;
		writerCache = new HlWriterCache();
		sourceTexts = [];
	}

	public function encodeHashLink(code:HlCode):haxe.io.Bytes
		return HlWriter.encode(code, writerCache);

	public function writeHashLink(code:HlCode, path:String):Void
		HlWriter.writeFile(code, path, writerCache);

	/** Wasm guests import their host services through this stdlib interface. */
	static function hostInterfaces(target:String):{interfaces:Array<String>, projections:Array<String>}
		return switch target {
			case "wasm32" | "wasm-gc" | "wasmgc": {
					interfaces: ["stdlib/haxeon/wasm/HaxeonHost.hxi", "stdlib/haxeon/wasm/HaxeonCrypto.hxi"],
					projections: ["stdlib/haxeon/wasm/HaxeonHost.hxmap", "stdlib/haxeon/wasm/HaxeonCrypto.hxmap"]
				};
			case _: {interfaces: [], projections: []};
		};

	/**
	 * Stdlib modules a Wasm host calls into, compiled into every guest that shares linear memory with its host
	 * (haxeon.wasm.HostError reads its message from that memory): wasm32 always, wasm-gc when it imports memory.
	 */
	static function hostSources(request:CompilerRequest):Array<String>
		return switch request.target {
			case "wasm32": ["stdlib/haxeon/wasm/HostError.hx"];
			case "wasm-gc" | "wasmgc" if (request.importMemory == true): ["stdlib/haxeon/wasm/HostError.hx"];
			case _: [];
		};

	public function prepare(request:CompilerRequest, report:String->Void):Compiler {
		var host = hostInterfaces(request.target),
			interfacePaths = request.ffiInterfaces.concat(host.interfaces),
			projectionPaths = request.ffiProjections.concat(host.projections);
		var interfaces:Array<FfiInterfaceSource> = [for (path in interfacePaths) {path: path, text: read(path)}],
			projections:Array<FfiProjectionSource> = [for (path in projectionPaths) {path: path, text: read(path)}],
			identity = Json.stringify({
				target: request.target,
				importMemory: request.importMemory,
				sharedMemory: request.sharedMemory == true,
				entry: request.entry,
				defines: request.defines,
				roots: request.roots,
				packageRoots: request.packageRoots,
				paths: request.paths,
				interfaces: interfaces,
				projections: projections
			});
		if (configuration != identity)
			reset();
		if (compiler != null)
			for (path in request.paths) {
				var before = sourceTexts.get(path);
				var after = readChanged(path);
				if (before != null && after != before && hasStructuralDeclaration(before, after)) {
					reset();
					break;
				}
			}
		if (compiler == null) {
			interfaces = [for (path in interfacePaths) {path: path, text: read(path)}];
			projections = [for (path in projectionPaths) {path: path, text: read(path)}];
		}
		// Modules resolved lazily (notably stdlib) have absolute source paths.
		// Refresh those too: retaining only the explicit manifest would cache stale imports.
		if (compiler != null) {
			for (state in compiler.modules) {
				var path = state.source.path;
				if (Path.isAbsolute(path) && !FileSystem.exists(path)) {
					reset();
					break;
				}
				if (Path.isAbsolute(path)) {
					var changed = readChanged(path);
					if (changed != state.source.text && hasStructuralDeclaration(state.source.text, changed)) {
						// A typedef/enum/abstract edit can change an unchanged class's field ABI.
						// Rebuild that semantic graph until transitive shape invalidation is complete.
						reset();
						break;
					}
				}
			}
		}
		// `report` is caller code, so nothing proved about the field survives a call to it; a local does.
		var existing = compiler;
		if (existing == null) {
			var resumed = request.live ? resumeLiveModule(request, identity, interfaces, projections, report) : null;
			var created = resumed == null ? new Compiler() : resumed;
			compiler = created;
			if (resumed == null) {
				compiler.enablePublicationTracking();
				CompilerIntrinsics.register(compiler);
			}
			var defines = request.defines.concat(CompilerDriver.targetDefines(request.target));
			compiler.configure("cli:" + request.target + ":" + defines.join("|"), "cli:" + request.target, defines);
			if (resumed == null) {
				for (source in projections) {
					report("loading FFI projection " + source.path);
					compiler.addFfiProjection(source.path, source.text);
				}
				for (source in HxiInterfaceOrder.dependenciesFirst(interfaces)) {
					report("loading FFI interface " + source.path);
					compiler.addFfiInterface(source.path, source.text);
				}
			}
			compiler.addSourceRoot("stdlib");
			for (root in request.roots)
				compiler.addSourceRoot(root);
			for (root in request.packageRoots)
				compiler.addPackageSourceRoot(root.packageName, root.path);
			configuration = identity;
		} else {
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
		SourceManifestLoader.load(compiler, ["stdlib"], hostModules, null, readChanged);
		for (path in hostModules)
			compiler.addRootModule(ModulePath.fromFile(SourceManifestLoader.projectPath(path, ["stdlib"])));
		for (path in request.paths)
			sourceTexts.set(path, read(path));
		return compiler;
	}

	/** Notes a live publication whose history `recordLiveState` writes once the session is idle. */
	public function recordLivePublication(output:String, marker:String):Void
		unrecordedPublication = {output: output, marker: marker};

	/**
	 * Records the history the last live revision was assembled from beside the module it published (`<output>.live.state`),
	 * keyed by that publication's `.live.full` marker, this session's configuration and the compiler program. A later
	 * session, such as the compile server started after the editor restarts, resumes it and patches the module the app is
	 * running instead of assembling a new module whose identity forces a reload. Encoding the history of an app takes
	 * seconds, so the server calls this between requests rather than on an edit's path. True when it wrote the history.
	 */
	public function recordLiveState():Bool {
		var publication = unrecordedPublication, current = configuration, active = compiler;
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
		File.saveBytes(output + ".live.state.tmp", bytes);
		CompilerDriver.replaceFile(output + ".live.state.tmp", output + ".live.state");
		return true;
	}

	public function hasUnrecordedLiveState():Bool
		return unrecordedPublication != null;

	/**
	 * The compiler that published the module now at the request's output, when its recorded history is for exactly that
	 * module (the whole module is on disk, its `.live.full` marker names the recorded revision) under this configuration
	 * and compiler. Anything else (no history, a stale or partial module, another compiler) starts a new module.
	 */
	function resumeLiveModule(request:CompilerRequest, identity:String, interfaces:Array<FfiInterfaceSource>, projections:Array<FfiProjectionSource>,
			report:String->Void):Null<Compiler> {
		var published = request.publishedOutput == null ? request.output : request.publishedOutput;
		if (published == null || !FileSystem.exists(published + ".live.full") || !FileSystem.exists(published + ".live.state"))
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
			var resumed = new Compiler(bytes.sub(separator + 1, bytes.length - separator - 1), CompilerIntrinsics.configuration(),
				new FfiConfiguration(interfaces, projections));
			report("resuming the published live module " + File.getContent(published + ".live.full"));
			return resumed;
		} catch (error:Dynamic) {
			report("live history could not be resumed (" + Std.string(error) + "); starting a new module");
			return null;
		}
	}

	static function liveStateKey(marker:String, configuration:String):String
		return marker + " " + build.execution.ContentDigest.makeHex(Bytes.ofString(configuration + "\n" + Path.withoutDirectory(Sys.programPath())));

	function read(path:String):String {
		return File.getContent(path);
	}

	function readChanged(path:String):Null<String> {
		// Metadata timestamps can have coarse resolution and miss same-size edits.
		// Compare actual source text so persistent compiler sessions always invalidate
		// from the bytes they compile, independent of filesystem timestamp behavior.
		return File.getContent(path);
	}

	static function hasStructuralDeclaration(before:String, after:String):Bool
		return structuralDeclarations(before) != structuralDeclarations(after);

	static function structuralDeclarations(source:String):String {
		var tokens = new Lexer(new SourceFile("<session-shapes>", source)).tokenize();
		var result:Array<String> = [];
		var depth = 0, capturing = false, bodyDepth = 0;
		for (token in tokens) {
			if (!capturing
				&& depth == 0
				&& (token.kind == TokenKind.Typedef
					|| token.kind == TokenKind.Enum
					|| (token.kind == TokenKind.Identifier && token.text == "abstract"))) {
				capturing = true;
				bodyDepth = 0;
			}
			if (capturing) {
				result.push(token.text);
				if (token.kind == TokenKind.LeftBrace)
					bodyDepth++;
				else if (token.kind == TokenKind.RightBrace) {
					bodyDepth--;
					if (bodyDepth == 0)
						capturing = false;
				} else if (token.kind == TokenKind.Semicolon && bodyDepth == 0)
					capturing = false;
			}
			if (token.kind == TokenKind.LeftBrace)
				depth++;
			else if (token.kind == TokenKind.RightBrace)
				depth--;
		}
		return result.join("\x1f");
	}
}
