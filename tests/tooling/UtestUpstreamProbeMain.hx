import compiler.Compiler;
import compiler.core.Diagnostic.CompileError;
import compiler.modules.ModulePath;
import compiler.runtime.CompilerIntrinsics;
import sys.FileSystem;
import sys.io.File;

/**
 * Reports the first Haxeon analysis blocker for every pinned upstream utest module, from the checkout's root:
 * `haxeon dev run --cp tests/tooling UtestUpstreamProbeMain` (docs/internals/UTEST_UPSTREAM_COMPATIBILITY.md).
 */
class UtestUpstreamProbeMain {
	static final upstreamRoot = "vendor/utest/src";

	/** The revision the report describes; another one would be reported as if it were this one. */
	static final expectedRevision = "a055e05e2e872ae12a32b53d0200612345059c38";

	static function main():Void {
		if (!FileSystem.exists("vendor/utest/haxelib.json"))
			fail("missing vendor/utest; run git submodule update --init vendor/utest");
		var git = new sys.io.Process("git", ["-C", "vendor/utest", "rev-parse", "HEAD"]),
			revision = StringTools.trim(git.stdout.readAll().toString());
		git.close();
		if (revision != expectedRevision)
			fail('vendor/utest revision mismatch: expected $expectedRevision, got $revision');
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
		CompilerIntrinsics.register(compiler);
		compiler.addStandardLibrarySourceRoot("stdlib");
		compiler.configure("utest-upstream-probe", "utest-upstream-probe",
			["haxe=4.3.7", "haxe_ver=4.3.7", "hl", "sys"]);
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
			var message = error.diagnostic.message;
			if (Sys.args().indexOf("--locations") >= 0)
				message = error.diagnostic.span.file.path + ":"
					+ error.diagnostic.span.file.lineAt(error.diagnostic.span.start) + ": " + message;
			row(module, "blocked", error.diagnostic.code, message);
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

	static function fail(message:String):Void {
		Sys.stderr().writeString(message + "\n");
		Sys.exit(1);
	}
}
