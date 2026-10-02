import compiler.tools.SourceManifestLoader;
import haxe.io.Path;
import sys.FileSystem;

/** A source file belongs to the same module however the file and its root are written. */
class SourceManifestPathMain {
	static function expect(actual:String, expected:String, label:String):Void {
		if (actual != expected)
			throw '$label: expected "$expected", got "$actual"';
	}

	static function main():Void {
		var cwd = Path.removeTrailingSlashes(Path.normalize(Sys.getCwd())),
			root = "tests/programs";
		expect(SourceManifestLoader.projectPath("tests/programs/add.hx", [root]), "add.hx", "relative file, relative root");
		expect(SourceManifestLoader.projectPath(cwd + "/tests/programs/add.hx", [root]), "add.hx", "absolute file, relative root");
		expect(SourceManifestLoader.projectPath("tests/programs/add.hx", [cwd + "/tests/programs"]), "add.hx", "relative file, absolute root");
		expect(SourceManifestLoader.projectPath(cwd + "/tests/programs/add.hx", [cwd + "/tests/programs"]), "add.hx", "absolute file, absolute root");
		expect(SourceManifestLoader.projectPath("./tests/../tests/programs/pkg/Util.hx", ["tests/./programs/"]), "pkg/Util.hx", "dot segments");
		expect(SourceManifestLoader.projectPath("tests\\programs\\pkg\\Util.hx", [root]), "pkg/Util.hx", "backslashes");
		// A file outside every root keeps its own (normalized) path.
		expect(SourceManifestLoader.projectPath("elsewhere/Other.hx", [root]), "elsewhere/Other.hx", "outside every root");
		// A root that is only a prefix of a directory name is not that directory.
		expect(SourceManifestLoader.projectPath("tests/programs-extra/x.hx", [root]), "tests/programs-extra/x.hx", "sibling with a shared prefix");
		Sys.println("PASS: source files resolve to their module under relative and absolute roots");
	}
}
