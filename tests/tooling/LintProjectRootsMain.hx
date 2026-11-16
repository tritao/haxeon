import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;

/**
 * `haxeon lint` resolves each file's imports against its own project, so a file gets the same answer alone or listed after files
 * from other packages. Here the app imports a dependency's module that declares a name another import also brings in, so the run
 * must not be sorted; that is only visible through the dependency's source root, which the app's manifest names.
 */
class LintProjectRootsMain {
	static function main():Void {
		var base = Path.join([FileSystem.absolutePath("out"), "lint-project-roots-" + Std.random(0x7fffffff)]);
		for (directory in ["dep/src/kit", "app/src/app", "app/src/other"])
			FileSystem.createDirectory(Path.join([base, directory]));
		write(base, "dep/haxeon.json", '{"version":1,"package":{"name":"kit"},"sourceRoots":["src"]}');
		write(base, "dep/src/kit/Shapes.hx",
			"package kit; class Circle { public function new() {} } class Square { public function new() {} }");
		write(base, "app/haxeon.json",
			'{"version":1,"package":{"name":"app"},"sourceRoots":["src"],"dependencies":{"kit":{"path":"../dep"}}}');
		write(base, "app/src/other/Circle.hx", "package other; class Circle { public function new() {} }");
		var main = "package app;\n\nimport other.Circle;\nimport kit.Shapes;\n\nfunction main() {}\n";
		write(base, "app/src/app/Main.hx", main);
		var mainPath = Path.join([base, "app/src/app/Main.hx"]),
			dependencyFile = Path.join([
				base,
				"dep/src/kit/Shapes.hx"
			]);
		for (arguments in [[mainPath], [dependencyFile, mainPath], [mainPath, dependencyFile]]) {
			var status = tools.LintCommand.run(["--fix", "--only", "import-order"].concat(arguments));
			if (status != 0 || File.getContent(mainPath) != main)
				throw 'lint sorted a run whose order decides what Circle means (files: ${arguments.length})';
		}
		removeTree(base);
		Sys.println("PASS: lint resolves each file against its own project, whatever else is listed");
	}

	static function write(base:String, relative:String, text:String):Void
		File.saveContent(Path.join([base, relative]), text);

	static function removeTree(path:String):Void {
		if (FileSystem.isDirectory(path)) {
			for (name in FileSystem.readDirectory(path))
				removeTree(Path.join([path, name]));
			FileSystem.deleteDirectory(path);
		} else
			FileSystem.deleteFile(path);
	}
}
