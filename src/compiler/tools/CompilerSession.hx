package compiler.tools;

import compiler.Compiler;
import compiler.runtime.CompilerIntrinsics;
import haxe.Json;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;

/** One reusable semantic compiler, reset whenever its source/FFI configuration changes. */
class CompilerSession {
	var compiler:Null<Compiler>;
	var configuration:Null<String>;

	public function new() {}

	public function reset():Void {
		compiler = null;
		configuration = null;
	}

	public function prepare(request:CompilerRequest, report:String->Void):Compiler {
		var interfaces = [for (path in request.ffiInterfaces) {path: path, text: File.getContent(path)}],
			projections = [for (path in request.ffiProjections) {path: path, text: File.getContent(path)}],
			identity = Json.stringify({
				target: request.target, entry: request.entry, defines: request.defines, roots: request.roots,
				packageRoots: request.packageRoots, paths: request.paths,
				interfaces: interfaces, projections: projections
			});
		if (configuration != identity)
			reset();
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
				if (Path.isAbsolute(path))
					compiler.refreshLoadedSource(name, File.getContent(path));
			}
		}
		SourceManifestLoader.load(compiler, request.roots, request.paths, request.packageRoots);
		return compiler;
	}
}
