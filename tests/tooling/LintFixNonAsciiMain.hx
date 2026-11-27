import haxe.io.Path;
import haxeon.io.FileTree;
import sys.FileSystem;
import sys.io.File;

/**
 * `haxeon lint --fix` edits at token offsets, which count UTF-8 bytes, while a Haxe string index counts characters. With
 * characters of two and three bytes before every edit, removing an unused import, sorting the imports left and shortening an
 * argument must each still cut exactly what they mean to, together in one file.
 */
class LintFixNonAsciiMain {
	static function main():Void {
		var base = Path.join([FileSystem.absolutePath("out"), "lint-fix-non-ascii-" + Std.random(0x7fffffff)]);
		for (module in ["a.Alpha", "a.Unused", "zz.Zed"]) {
			var parts = module.split(".");
			FileSystem.createDirectory(Path.join([base, parts[0]]));
			File.saveContent(Path.join([base, parts[0], parts[1] + ".hx"]),
				'package ${parts[0]};\nclass ${parts[1]} {}\n');
		}
		var path = Path.join([base, "Main.hx"]);
		var body = 'function main() { new Zed(); new Alpha(); make("é", enabled: enabled); }\n';
		File.saveContent(path, '// Größe → ü\nimport zz.Zed;\nimport a.Unused;\nimport a.Alpha;\n\n$body');
		if (tools.LintCommand.run(["--fix", path]) != 0)
			throw "lint --fix failed";
		var fixed = File.getContent(path),
			wanted =
				'// Größe → ü\nimport a.Alpha;\nimport zz.Zed;\n\n${StringTools.replace(body, "enabled: enabled", "enabled:")}';
		if (fixed != wanted)
			throw 'lint --fix wrote:\n$fixed';
		FileTree.remove(base);
		Sys.println("PASS: lint --fix removes, sorts and shortens at the right place after non-ASCII text");
	}
}
