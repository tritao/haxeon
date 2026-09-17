package build.native;

import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;

/** Finds project-local C headers that can affect one source action. */
class NativeDependencyScanner {
	public static function dependencies(source:String, includeDirs:Array<String>):Array<String> {
		var found:Map<String, Bool> = [],
			active:Map<String, Bool> = [],
			result:Array<String> = [];
		scan(FileSystem.fullPath(source), includeDirs, found, active, result);
		result.sort(Reflect.compare);
		return result;
	}

	static function scan(file:String, includeDirs:Array<String>, found:Map<String, Bool>, active:Map<String, Bool>, result:Array<String>):Void {
		var canonical = Path.normalize(FileSystem.fullPath(file));
		if (active.exists(canonical) || !FileSystem.exists(canonical) || FileSystem.isDirectory(canonical))
			return;
		active.set(canonical, true);
		var includePattern = ~/^\s*#\s*include\s*[<"]([^">]+)[">]/;
		for (line in File.getContent(canonical).split("\n"))
			if (includePattern.match(line)) {
				var included = includePattern.matched(1),
					resolved = resolve(canonical, included, includeDirs);
				if (resolved != null && !found.exists(resolved)) {
					found.set(resolved, true);
					result.push(resolved);
					scan(resolved, includeDirs, found, active, result);
				}
			}
		active.remove(canonical);
	}

	static function resolve(source:String, included:String, includeDirs:Array<String>):Null<String> {
		var candidates = [Path.join([Path.directory(source), included])];
		for (directory in includeDirs)
			candidates.push(Path.join([directory, included]));
		for (candidate in candidates) {
			var normalized = Path.normalize(candidate);
			if (FileSystem.exists(normalized) && !FileSystem.isDirectory(normalized))
				return Path.normalize(FileSystem.fullPath(normalized));
		}
		return null;
	}
}
