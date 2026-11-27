import haxe.io.Path;
import haxeon.io.FileTree;
import sys.FileSystem;
import sys.io.File;

/**
 * `haxeon lint` reports a call argument written `name: name`, and `--fix` writes it `name:`. An argument that passes anything
 * else under that name (`name: name.field`, `name: name + 1`), an argument of another name, and an object literal's field are
 * left as they are. A character before the argument that takes more than one UTF-8 byte must not move the cut.
 */
class LintRedundantArgumentNameMain {
	static function main():Void {
		var base = Path.join([FileSystem.absolutePath("out"),
			"lint-redundant-argument-name-" + Std.random(0x7fffffff)]);
		FileSystem.createDirectory(base);
		var path = Path.join([base, "Main.hx"]);
		var kept = 'make(enabled: enabled.value, count: count + 1, other: enabled, {enabled: enabled});\n';
		File.saveContent(path, 'function main() {\n\tmake("é→", enabled: enabled, onSubmit: onSubmit);\n\t$kept}\n');
		if (tools.LintCommand.run(["--only", "redundant-argument-name", path]) != 1)
			throw "lint did not report enabled: enabled";
		if (tools.LintCommand.run(["--fix", "--only", "redundant-argument-name", path]) != 0)
			throw "lint --fix failed";
		var fixed = File.getContent(path);
		if (fixed != 'function main() {\n\tmake("é→", enabled:, onSubmit:);\n\t$kept}\n')
			throw 'lint --fix wrote: $fixed';
		if (tools.LintCommand.run(["--only", "redundant-argument-name", path]) != 0)
			throw "lint reported the short form";
		FileTree.remove(base);
		Sys.println("PASS: lint writes a call argument name: name as name:, and leaves every other argument");
	}
}
