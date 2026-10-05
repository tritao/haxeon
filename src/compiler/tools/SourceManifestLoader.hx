package compiler.tools;

import compiler.Compiler;
import compiler.tools.CompilerRequest.PackageSourceRoot;
import sys.FileSystem;
import sys.io.File;

/** A source root as every file under it is matched: its canonical path with a trailing slash, and the package its files belong to, if any. */
private typedef ResolvedRoot = {
	final prefix:String;
	final packagePrefix:Null<String>;
}

/** Loads a deterministic explicit source manifest into a compiler instance. */
class SourceManifestLoader {
	public static function load(compiler:Compiler, roots:Array<String>, paths:Array<String>, ?packageRoots:Array<PackageSourceRoot>,
			?readSource:String->Null<String>):Void {
		var ordered = paths.copy(),
			resolvedPackages = resolve(packageRoots == null ? [] : [for (root in packageRoots) root.path],
				packageRoots == null ? [] : [for (root in packageRoots) root.packageName]),
			resolvedRoots = resolve(roots);
		ordered.sort(Reflect.compare);
		for (path in ordered)
			try {
				var source = readSource == null ? File.getContent(path) : readSource(path);
				if (source != null)
					compiler.update(locate(path, resolvedRoots, resolvedPackages), source);
			} catch (error:Dynamic) {
				throw "Could not load compiler source " + path + ": " + Std.string(error);
			}
	}

	/**
	 * The path of a source file as its module sees it: relative to the source root it is under. A file and a root match
	 * however each is written (relative to the working directory, absolute, with `.` or `..` segments), so a file given
	 * by absolute path under a relative root still resolves to its module.
	 */
	public static function projectPath(path:String, roots:Array<String>, ?packageRoots:Array<PackageSourceRoot>):String
		return locate(path, resolve(roots),
			resolve(packageRoots == null ? [] : [for (root in packageRoots) root.path],
				packageRoots == null ? [] : [for (root in packageRoots) root.packageName]));

	/** The roots in `paths` resolved once, so that placing each of many files does not canonicalize every root again. */
	static function resolve(paths:Array<String>, ?packageNames:Array<String>):Array<ResolvedRoot> {
		var result:Array<ResolvedRoot> = [];
		for (index in 0...paths.length) {
			var prefix = canonicalPath(paths[index]);
			if (!StringTools.endsWith(prefix, "/"))
				prefix += "/";
			result.push({prefix: prefix, packagePrefix: packageNames == null ? null : packageNames[index].split(".").join("/") + "/"});
		}
		return result;
	}

	static function locate(path:String, roots:Array<ResolvedRoot>, packageRoots:Array<ResolvedRoot>):String {
		var canonicalFile = canonicalPath(path);
		for (root in packageRoots)
			if (StringTools.startsWith(canonicalFile, root.prefix)) {
				var relative = canonicalFile.substring(root.prefix.length, canonicalFile.length);
				return StringTools.startsWith(relative, root.packagePrefix) ? relative : root.packagePrefix + relative;
			}
		for (root in roots)
			if (StringTools.startsWith(canonicalFile, root.prefix))
				return canonicalFile.substring(root.prefix.length, canonicalFile.length);
		return normalizePath(path);
	}

	/** An absolute path with forward slashes and no `.` or `..` segments; a path that does not exist is resolved against the working directory too. */
	static function canonicalPath(path:String):String {
		var normalized = normalizePath(path);
		return normalizePath(haxe.io.Path.normalize(haxe.io.Path.isAbsolute(normalized) ? normalized : FileSystem.absolutePath(normalized)));
	}

	static function normalizePath(path:String):String
		return path.indexOf("\\") < 0 ? path : path.split("\\").join("/");
}
