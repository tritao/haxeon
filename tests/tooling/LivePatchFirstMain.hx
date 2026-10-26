import compiler.tools.CompilerArguments;
import compiler.tools.CompilerDriver;
import compiler.tools.CompilerSession;
import sys.FileSystem;
import sys.io.File;

/**
 * A live edit that patches publishes the patch and its stamp before the full module is written, and the `.live.full`
 * marker tells a reloading host when the module and `.hli` belong to the published description: absent from the moment
 * a publication starts until every file a reload reads has been written, then equal to the stamp.
 */
class LivePatchFirstMain {
	static function main():Void {
		var root = FileSystem.fullPath(".") + "/out/live-patch-first-test-" + Std.random(0x3fffffff);
		FileSystem.createDirectory(root);
		var main = root + "/Main.hx", output = root + "/live.hl";
		function write(value:Int):Void
			File.saveContent(main,
				"class Main {\n"
				+ "  @:keep public static function start(arguments:String):Void {}\n"
				+ "  @:keep public static function tick():Int return " + value + ";\n"
				+ "  @:keep public static function close():Int return 0;\n"
				+ "  @:keep public static function saveState():String return \"\";\n"
				+ "  @:keep public static function restoreState(state:String):Void {}\n"
				+ "  public static function main():Void {}\n"
				+ "}\n");
		var session = new CompilerSession();
		var snapshots:Array<{marker:Bool, stamp:Bool, patch:Bool, moduleStale:Bool}> = [];
		function build(value:Int):Dynamic {
			write(value);
			var before = FileSystem.exists(output) ? FileSystem.stat(output).mtime.getTime() : -1.0;
			snapshots = [];
			CompilerDriver.compile(CompilerArguments.parse(["--target=hl", "--entry=Main", "--root=" + root, "--live", "--output=" + output, main]), _ -> {},
				session, null, () -> snapshots.push({
					marker: FileSystem.exists(output + ".live.full"),
					stamp: FileSystem.exists(output + ".live.stamp"),
					patch: FileSystem.exists(output + ".hlp"),
					moduleStale: FileSystem.stat(output).mtime.getTime() == before
				}));
			return haxe.Json.parse(File.getContent(output + ".live.json"));
		}
		var first = build(1);
		expect(File.getContent(output + ".live.full") == first.moduleIdentity + ":" + Std.string(first.revision), "a finished build must leave the marker at its key");
		expect(File.getContent(output + ".live.stamp") == File.getContent(output + ".live.full"), "the marker must equal the stamp once the build is whole");
		var second = build(2);
		expect(second.patchAvailable == true && second.requiresReload == false, "a body edit must patch");
		expect(snapshots.length == 1, "the publication callback must fire once");
		var seen = snapshots[0];
		expect(seen.stamp && seen.patch, "the stamp and patch must be visible when the callback fires");
		expect(!seen.marker, "the marker must be gone while the module on disk is the previous revision");
		expect(seen.moduleStale, "the full module must be written after the patch is published");
		expect(File.getContent(output + ".live.full") == second.moduleIdentity + ":" + Std.string(second.revision), "the marker must name the new revision once the module is written");
		expect(File.getContent(output + ".live.full") == File.getContent(output + ".live.stamp"), "marker and stamp must agree after the build");
		expect(File.getBytes(output + ".hli").length > 0 && File.getContent(output + ".build-id").length > 0, "side files must follow the module");
		for (path in FileSystem.readDirectory(root))
			FileSystem.deleteFile(root + "/" + path);
		FileSystem.deleteDirectory(root);
		Sys.println("PASS: a live patch is published before the full module and the marker vouches for the module");
	}

	static function expect(condition:Bool, message:String):Void {
		if (!condition)
			throw message;
	}
}
