package compiler.tools;

import compiler.Compiler;
import compiler.ffi.HxiInterfaceOrder;
import compiler.runtime.CompilerIntrinsics;
import compiler.hl.HlCode;
import compiler.hl.HlWriter;
import compiler.hl.HlWriterCache;
import haxe.Json;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;

/** One reusable semantic compiler, reset whenever its source/FFI configuration changes. */
class CompilerSession {
	var compiler:Null<Compiler>;
	var configuration:Null<String>;
	var writerCache = new HlWriterCache();
	var sourceTexts:Map<String, String> = [];

	public function new() {}

	public function reset():Void {
		compiler = null;
		configuration = null;
		writerCache = new HlWriterCache();
		sourceTexts = [];
	}

	public function encodeHashLink(code:HlCode):haxe.io.Bytes
		return HlWriter.encode(code, writerCache);

	public function writeHashLink(code:HlCode, path:String):Void
		HlWriter.writeFile(code, path, writerCache);

	public function prepare(request:CompilerRequest, report:String->Void):Compiler {
		var interfaces = [for (path in request.ffiInterfaces) {path: path, text: read(path)}],
			projections = [for (path in request.ffiProjections) {path: path, text: read(path)}],
			identity = Json.stringify({
				target: request.target,
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
		if (compiler != null) for (path in request.paths) {
			var before = sourceTexts.get(path);
			var after = readChanged(path);
			if (before != null && after != before && hasStructuralDeclaration(before, after)) {
				reset();
				break;
			}
		}
		if (compiler == null) {
			interfaces = [for (path in request.ffiInterfaces) {path: path, text: read(path)}];
			projections = [for (path in request.ffiProjections) {path: path, text: read(path)}];
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
		if (compiler == null) {
			compiler = new Compiler();
			compiler.enablePublicationTracking();
			CompilerIntrinsics.register(compiler);
			var defines = request.defines.concat(CompilerDriver.targetDefines(request.target));
			compiler.configure("cli:" + request.target + ":" + defines.join("|"), "cli:" + request.target, defines);
			for (source in projections) {
				report("loading FFI projection " + source.path);
				compiler.addFfiProjection(source.path, source.text);
			}
			for (source in HxiInterfaceOrder.dependenciesFirst(interfaces)) {
				report("loading FFI interface " + source.path);
				compiler.addFfiInterface(source.path, source.text);
			}
			compiler.addSourceRoot("stdlib");
			for (root in request.roots)
				compiler.addSourceRoot(root);
			for (root in request.packageRoots)
				compiler.addPackageSourceRoot(root.packageName, root.path);
			configuration = identity;
		} else {
			report("reusing compiler session");
			for (name => state in compiler.modules) {
				var path = state.source.path;
				if (Path.isAbsolute(path)) {
					var changed = readChanged(path);
					if (changed != null)
						compiler.refreshLoadedSource(name, changed);
				}
			}
		}
		SourceManifestLoader.load(compiler, request.roots, request.paths, request.packageRoots, readChanged);
		for (path in request.paths) sourceTexts.set(path, read(path));
		return compiler;
	}

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
		return hasDeclaration(before) || hasDeclaration(after);

	static function hasDeclaration(source:String):Bool
		return source.indexOf("typedef ") >= 0 || source.indexOf("enum ") >= 0 ||
			source.indexOf("abstract ") >= 0;
}
