import compiler.Compiler;
import compiler.Diagnostic.CompileError;
import compiler.modules.ModulePath;
import compiler.runtime.RuntimeNatives;
import sys.FileSystem;
import sys.io.File;

/** Reports the first Haxeon analysis blocker for every pinned upstream utest module. */
class UtestUpstreamProbeMain {
	static final upstreamRoot = "vendor/utest/src";

	static function main():Void {
		var paths:Array<String> = [];
		collect(upstreamRoot + "/utest", paths);
		paths.sort(Reflect.compare);
		Sys.println("| Module | Status | Diagnostic | First blocker |");
		Sys.println("| --- | --- | --- | --- |");
		for (path in paths)
			probe(path, paths);
	}

	static function probe(entryPath:String, paths:Array<String>):Void {
		var compiler = new Compiler();
		RuntimeNatives.register(compiler);
		compiler.configure("utest-upstream-probe", "utest-upstream-probe", ["haxe=4.3.7", "haxe_ver=4.3.7", "hl", "sys"]);
		compiler.update("haxe/PosInfos.hx", File.getContent("stdlib/haxe/PosInfos.hx"));
		for (path in paths) {
			var relative = path.substring(upstreamRoot.length + 1, path.length);
			compiler.update(relative, File.getContent(path));
		}
		var relative = entryPath.substring(upstreamRoot.length + 1, entryPath.length);
		var module = ModulePath.fromFile(relative);
		compiler.update("__probe__.hx", 'import $module; function main():Int return 0;');
		try {
			compiler.analyze("__probe__");
			row(module, "pass", "-", "-");
		} catch (error:CompileError) {
			row(module, "blocked", error.diagnostic.code, error.diagnostic.message);
		} catch (error:Dynamic) {
			row(module, "blocked", "internal", Std.string(error));
		}
	}

	static function collect(directory:String, paths:Array<String>):Void {
		for (name in FileSystem.readDirectory(directory)) {
			var path = directory + "/" + name;
			if (FileSystem.isDirectory(path))
				collect(path, paths);
			else if (StringTools.endsWith(name, ".hx"))
				paths.push(path);
		}
	}

	static function row(module:String, status:String, diagnostic:String, blocker:String):Void {
		blocker = StringTools.replace(blocker, "|", "\\|");
		blocker = StringTools.replace(blocker, "\n", " ");
		Sys.println('| `$module` | $status | `$diagnostic` | $blocker |');
	}
}
