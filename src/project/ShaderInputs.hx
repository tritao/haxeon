package project;

import build.Target;
import build.TargetLayout;
import haxe.io.Path;
import sys.FileSystem;

/** The project's user-authored shader directories and the generated module root. */
class ShaderInputs {
	public static function roots(project:ResolvedProject):Array<String> {
		var roots = [];
		for (sourceRoot in project.rootPackage.sourceRoots) {
			var path = Path.join([sourceRoot, "shaders"]);
			if (FileSystem.exists(path) && FileSystem.isDirectory(path))
				roots.push(path);
		}
		return roots;
	}

	public static function output(buildRoot:String, target:Target):String
		return Path.join([buildRoot, TargetLayout.directoryFor(target), "generated"]);

	public static function sources(output:String):String
		return Path.join([output, "shaders.sources"]);

	public static function dependencies(output:String):String
		return Path.join([output, "shaders.dependencies"]);
}
