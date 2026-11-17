import haxe.io.Path;
import project.MissingPath;
import sys.FileSystem;
import sys.io.File;

/**
 * A missing path a manifest names is reported with its cause when it lies in a git submodule that was never initialized: an empty
 * directory its repository's .gitmodules lists, found also through a symlinked tree (as the example builds link vendor/).
 */
class MissingPathMain {
	static function main():Void {
		var root = Path.join([
			Sys.getEnv("TMPDIR") == null ? "/tmp" : Sys.getEnv("TMPDIR"),
			'haxeon-missing-path-${Std.random(1000000)}'
		]),
			repository = Path.join([root, "repository"]);
		FileSystem.createDirectory(Path.join([repository, "vendor", "kit"]));
		FileSystem.createDirectory(Path.join([repository, "vendor", "filled"]));
		File.saveContent(Path.join([repository, "vendor", "filled", "present.txt"]), "x");
		File.saveContent(Path.join([repository, ".gitmodules"]),
			'[submodule "vendor/kit"]\n\tpath = vendor/kit\n\turl = https://example.invalid/kit.git\n'
			+ '[submodule "vendor/filled"]\n\tpath = vendor/filled\n\turl = https://example.invalid/filled.git\n');
		var plain = MissingPath.describe("Native input", Path.join([repository, "elsewhere", "CMakeLists.txt"]));
		if (plain.indexOf("not initialized") >= 0)
			throw 'A path outside any submodule was reported as one: $plain';
		var inKit = MissingPath.describe("Native input", Path.join([repository, "vendor", "kit", "CMakeLists.txt"]));
		if (inKit.indexOf("vendor/kit is a git submodule that is not initialized") < 0
			|| inKit.indexOf("git submodule update --init vendor/kit") < 0)
			throw 'An uninitialized submodule was not named: $inKit';
		var filled = MissingPath.describe("Native input", Path.join([repository, "vendor", "filled", "missing.txt"]));
		if (filled.indexOf("not initialized") >= 0)
			throw 'A missing file in an initialized submodule was blamed on it: $filled';
		// The example builds link the checkout's vendor/ into a tree of their own.
		var tree = Path.join([root, "tree"]);
		FileSystem.createDirectory(tree);
		if (Sys.systemName() != "Windows") {
			Sys.command("ln", ["-s", Path.join([repository, "vendor"]), Path.join([tree, "vendor"])]);
			var linked = MissingPath.describe("Native input", Path.join([tree, "vendor", "kit", "CMakeLists.txt"]));
			if (linked.indexOf("vendor/kit is a git submodule that is not initialized") < 0)
				throw 'An uninitialized submodule reached through a symlink was not named: $linked';
		}
		Sys.command("rm", ["-rf", root]);
		Sys.println("PASS: a missing path in an uninitialized submodule names the submodule and the command that initializes it");
	}
}
