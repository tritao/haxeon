package compiler.tools;

import compiler.Compiler;
import compiler.core.InternalError;
import compiler.modules.ModulePath;
import compiler.tools.CompilerRequest.PackageSourceRoot;
import sys.FileSystem;
import sys.io.File;

/** A source root as every file under it is matched: its canonical path with a trailing slash, and the package its files belong to, if any. */
private typedef ResolvedRoot = {
	final prefix:String;
	final packagePrefix:Null<String>;
}

/** Where the loader puts a file of the manifest: its module, its path as the module sees it, its physical path, and whether it is package code. */
typedef SourcePlace = {
	final module:String;
	final path:String;
	final physical:String;
	final packageCode:Bool;
}

/** Loads a deterministic explicit source manifest into a compiler instance. */
class SourceManifestLoader {
	/**
	 * `dependencyRoots`: the roots whose files are a dependency's, package code (`ModuleState.packageCode`). `places`, a session's,
	 * keeps where each file went for the next load of the same roots, which then places only the files new to it.
	 */
	public static function load(compiler:Compiler, roots:Array<String>, paths:Array<String>,
			?packageRoots:Array<PackageSourceRoot>,
			?readSource:String->Null<String>, ?dependencyRoots:Array<String>, ?places:Map<String, SourcePlace>):Void {
		var ordered = paths.copy(),
			resolvedPackages = resolve(packageRoots == null ? [] : [for (root in packageRoots) root.path],
				packageRoots == null ? [] : [for (root in packageRoots) root.packageName]),
			resolvedRoots = resolve(roots),
			dependencies = resolve(dependencyRoots == null ? [] : dependencyRoots),
			current = "";
		ordered.sort(Reflect.compare);
		// One handler for the whole manifest: entering a try costs an allocation.
		try {
			for (path in ordered) {
				current = path;
				var source = readSource == null ? File.getContent(path) : readSource(path);
				if (source == null)
					continue;
				var place = places == null ? null : places.get(path);
				if (place == null) {
					var physical = canonicalPath(path),
						located = locate(path, physical, resolvedRoots, resolvedPackages);
					place = {
						module: ModulePath.fromFile(located),
						path: located,
						physical: physical,
						packageCode: within(physical, dependencies)
					};
					if (places != null)
						places.set(path, place);
				}
				compiler.update(place.path, source, place.module, place.physical, place.packageCode);
			}
		} catch (error:Dynamic) {
			throw new InternalError("Could not load compiler source " + current + ": " + Std.string(error));
		}
	}

	/**
	 * The path of a source file as its module sees it: relative to the source root it is under. A file and a root match
	 * however each is written (relative to the working directory, absolute, with `.` or `..` segments), so a file given
	 * by absolute path under a relative root still resolves to its module.
	 */
	public static function projectPath(path:String, roots:Array<String>, ?packageRoots:Array<PackageSourceRoot>):String
		return locate(path, canonicalPath(path), resolve(roots),
			resolve(packageRoots == null ? [] : [for (root in packageRoots) root.path],
			packageRoots == null ? [] : [for (root in packageRoots) root.packageName]));

	/** The roots in `paths` resolved once, so that placing each of many files does not canonicalize every root again. */
	static function resolve(paths:Array<String>, ?packageNames:Array<String>):Array<ResolvedRoot> {
		var result:Array<ResolvedRoot> = [];
		for (index in 0...paths.length) {
			var prefix = canonicalPath(paths[index]);
			if (!StringTools.endsWith(prefix, "/"))
				prefix += "/";
			result.push({
				prefix: prefix,
				packagePrefix: packageNames == null ? null : packageNames[index].split(".").join("/") + "/"
			});
		}
		return result;
	}

	/**
	 * The path of a file `relative` to a source root whose files belong to `packageName`: under the package's directory, whether
	 * the root holds that directory (`ui/Button.hx`) or is it (`Button.hx`).
	 */
	public static function packagePath(relative:String, packageName:String):String
		return packagedPath(relative, packageName.split(".").join("/") + "/");

	static function packagedPath(relative:String, packagePrefix:String):String
		return StringTools.startsWith(relative, packagePrefix) ? relative : packagePrefix + relative;

	static function within(canonicalFile:String, roots:Array<ResolvedRoot>):Bool {
		for (root in roots)
			if (StringTools.startsWith(canonicalFile, root.prefix))
				return true;
		return false;
	}

	static function locate(path:String, canonicalFile:String, roots:Array<ResolvedRoot>,
			packageRoots:Array<ResolvedRoot>):String {
		for (root in packageRoots)
			if (StringTools.startsWith(canonicalFile, root.prefix))
				return packagedPath(canonicalFile.substring(root.prefix.length, canonicalFile.length),
					root.packagePrefix);
		for (root in roots)
			if (StringTools.startsWith(canonicalFile, root.prefix))
				return canonicalFile.substring(root.prefix.length, canonicalFile.length);
		return normalizePath(path);
	}

	/** An absolute path with forward slashes and no `.` or `..` segments; a path that does not exist is resolved against the working directory too. */
	static function canonicalPath(path:String):String {
		var normalized = normalizePath(path);
		return normalizePath(haxe.io.Path.normalize(haxe.io.Path.isAbsolute(normalized)
			? normalized : FileSystem.absolutePath(normalized)));
	}

	static function normalizePath(path:String):String
		return path.indexOf("\\") < 0 ? path : path.split("\\").join("/");
}
