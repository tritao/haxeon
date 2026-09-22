package compiler.tools;

import compiler.Compiler;
import compiler.runtime.CompilerIntrinsics;
import compiler.hl.HlCode;
import compiler.hl.HlWriter;
import compiler.hl.HlWriterCache;
import haxe.Json;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;

private typedef CachedSource = {
	final size:Int;
	final modified:Float;
	final changed:Float;
	final text:String;
}

/** One reusable semantic compiler, reset whenever its source/FFI configuration changes. */
class CompilerSession {
	var compiler:Null<Compiler>;
	var configuration:Null<String>;
	final trustFileMetadata:Bool;
	final sources:Map<String, CachedSource> = [];
	var writerCache = new HlWriterCache();

	public function new(trustFileMetadata = false)
		this.trustFileMetadata = trustFileMetadata;

	public function reset():Void {
		compiler = null;
		configuration = null;
		sources.clear();
		writerCache = new HlWriterCache();
	}

	public function encodeHashLink(code:HlCode):haxe.io.Bytes
		return HlWriter.encode(code, writerCache);

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
			}
		}
		if (compiler == null) {
			compiler = new Compiler();
			CompilerIntrinsics.register(compiler);
			var defines = request.defines.concat(CompilerDriver.targetDefines(request.target));
			compiler.configure("cli:" + request.target + ":" + defines.join("|"), "cli:" + request.target, defines);
			for (source in projections) {
				report("loading FFI projection " + source.path);
				compiler.addFfiProjection(source.path, source.text);
			}
			for (source in interfaces) {
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
		return compiler;
	}

	function read(path:String):String {
		if (!trustFileMetadata)
			return File.getContent(path);
		var changed = readChanged(path);
		return changed == null ? sources.get(path).text : changed;
	}

	function readChanged(path:String):Null<String> {
		if (!trustFileMetadata)
			return File.getContent(path);
		var stat = FileSystem.stat(path),
			cached = sources.get(path),
			modified = stat.mtime.getTime(),
			changed = stat.ctime.getTime();
		if (cached != null && cached.size == stat.size && cached.modified == modified && cached.changed == changed)
			return null;
		var text = File.getContent(path);
		sources.set(path, {
			size: stat.size,
			modified: modified,
			changed: changed,
			text: text
		});
		return text;
	}
}
