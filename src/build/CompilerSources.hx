package build;

import haxe.io.Path;
import sys.FileSystem;

/**
 * Where the compiler's own sources are, for building it with stock Haxe: the `src` directory and the portable package beside it
 * (`lib/haxeon-io`). Every place that builds or fingerprints the compiler asks here, so the class path is written once. `common.hxml`
 * lists the same two directories for commands typed or scripted from the repository root.
 */
class CompilerSources {
	/** `source` (a `src` directory) followed by the portable package next to it, when there is one. */
	public static function roots(source:String):Array<String> {
		var result = [source], library = Path.join([Path.directory(Path.removeTrailingSlashes(source)), "lib", "haxeon-io"]);
		if (FileSystem.exists(library))
			result.push(library);
		return result;
	}

	/** `-cp` arguments for every root. */
	public static function classPath(source:String):Array<String> {
		var result = [];
		for (root in roots(source)) {
			result.push("-cp");
			result.push(root);
		}
		return result;
	}
}
