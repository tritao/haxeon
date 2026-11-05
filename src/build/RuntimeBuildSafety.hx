package build;

import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;

/** Detect libraries held by this process in the directory about to receive a native build. */
class RuntimeBuildSafety {
	public static function conflictingLibrary(outputDirectory:String):Null<String> {
		#if hl
		if (!FileSystem.exists(outputDirectory))
			return null;
		var output = FileSystem.fullPath(outputDirectory);
		if (Sys.systemName() == "Linux") {
			var outputFiles:Map<String, Bool> = [];
			for (name in FileSystem.readDirectory(output)) {
				var candidate = Path.join([output, name]);
				if (isLibrary(candidate) && FileSystem.exists(candidate)) {
					var target = FileSystem.stat(candidate);
					outputFiles.set('${target.dev}:${target.ino}', true);
				}
			}
			// The loader may resolve symlinks or choose a library outside LD_LIBRARY_PATH.
			// Inspect the actual mappings, including mappings whose original file was unlinked.
			var maps = File.read("/proc/self/maps"), contents:String;
			try {
				contents = maps.readAll().toString();
				maps.close();
			} catch (failure:Dynamic) {
				maps.close();
				throw failure;
			}
			var seen:Map<String, Bool> = [];
			for (line in contents.split("\n")) {
				var start = line.indexOf("/");
				if (start < 0)
					continue;
				var loaded = line.substr(start);
				if (StringTools.endsWith(loaded, " (deleted)"))
					loaded = loaded.substr(0, loaded.length - " (deleted)".length);
				if (!isLibrary(loaded) || seen.exists(loaded))
					continue;
				seen.set(loaded, true);
				if (sameDirectory(Path.directory(loaded), output))
					return loaded;
				// A symlink or hard link in the output directory can name the mapped inode.
				if (FileSystem.exists(loaded)) {
					var mapped = FileSystem.stat(loaded);
					if (outputFiles.exists('${mapped.dev}:${mapped.ino}'))
						return loaded;
				}
			}
			return null;
		}
		// Other desktop loaders do not expose mappings through /proc. Conservatively
		// reject an output directory present in their native-library search paths.
		var variables = Sys.systemName() == "Windows" ? ["PATH"] : ["DYLD_LIBRARY_PATH", "DYLD_FALLBACK_LIBRARY_PATH"],
			separator = Sys.systemName() == "Windows" ? ";" : ":";
		for (variable in variables) {
			var value = Sys.getEnv(variable);
			if (value == null)
				continue;
			for (directory in value.split(separator))
				if (directory != "" && FileSystem.exists(directory) && sameDirectory(directory, output))
					for (name in FileSystem.readDirectory(output))
						if (isLibrary(name))
							return Path.join([output, name]);
		}
		#end
		return null;
	}

	#if hl
	static function sameDirectory(first:String, second:String):Bool {
		if (!FileSystem.exists(first) || !FileSystem.exists(second))
			return Path.normalize(first) == Path.normalize(second);
		var left = FileSystem.fullPath(first), right = FileSystem.fullPath(second);
		return Sys.systemName() == "Windows" ? left.toLowerCase() == right.toLowerCase() : left == right;
	}

	static function isLibrary(path:String):Bool {
		var name = Path.withoutDirectory(path).toLowerCase();
		return StringTools.endsWith(name, ".hdll") || StringTools.endsWith(name, ".dll") || StringTools.endsWith(name, ".dylib")
			|| StringTools.endsWith(name, ".so") || name.indexOf(".so.") >= 0;
	}
	#end
}
