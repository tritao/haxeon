import compiler.tools.CompilerArguments;
import compiler.tools.CompilerDriver;
import compiler.tools.CompilerSession;
import sys.FileSystem;
import sys.io.File;

/**
 * A live session that starts after another one published the module (the compile server started after the editor
 * restarts) patches that module: it resumes the history recorded beside it, so the first edit keeps the module identity
 * and continues its revisions instead of assembling a new module the running app must reload. A module whose recorded
 * history does not match it starts a new module.
 */
class LiveRestartMain {
	static function main():Void {
		var root = FileSystem.fullPath(".") + "/out/live-restart-test-" + Std.random(0x3fffffff);
		FileSystem.createDirectory(root);
		var main = root + "/Main.hx", output = root + "/live.hl";
		function build(session:CompilerSession, value:Int):Dynamic {
			File.saveContent(main,
				"class Main {\n"
				+ "  @:keep public static function start(arguments:String):Void {}\n"
				+ "  @:keep public static function tick():Int return "
				+ value
				+ ";\n"
				+ "  @:keep public static function scale():Float return 0.25 * "
				+ value
				+ ";\n"
				+ "  @:keep public static function close():Int return 0;\n"
				+ "  @:keep public static function saveState():String return \"\";\n"
				+ "  @:keep public static function restoreState(state:String):Void {}\n"
				+ "  public static function main():Void {}\n"
				+ "}\n");
			CompilerDriver.compile(CompilerArguments.parse([
				"--target=hl",
				"--entry=Main",
				"--root=" + root,
				"--live",
				"--output=" + output,
				main
			]), _ -> {}, session);
			return haxe.Json.parse(File.getContent(output + ".live.json"));
		}
		var original = new CompilerSession(), first = build(original, 1);
		// The same edit made in a session that kept its history, which the restarted session must match.
		var warm = build(original, 2);
		var reverted = build(original, 1);
		first = build(original, 1);
		expect(first.revision == reverted.revision, "a build that changes nothing must keep the published revision");
		// The compile server records the history once it is idle, and a new one resumes it.
		expect(original.recordLiveState(), "an idle session must record the published module's history");
		var restarted = new CompilerSession();
		// A live run warms its new worker with the unchanged program; that must not make the running app reload.
		var warmup = build(restarted, 1);
		expect(warmup.moduleIdentity == first.moduleIdentity, "a restarted session must keep the published module's identity");
		expect(warmup.requiresReload == false && (warmup.revision == first.revision || warmup.patchAvailable == true),
			"warming a restarted session must not force a reload");
		var edit = build(restarted, 2);
		expect(edit.moduleIdentity == first.moduleIdentity, "a restarted session must keep the published module's identity");
		expect(edit.revision == warmup.revision + 1, "a restarted session must continue the published revisions");
		expect(edit.patchAvailable == true && edit.requiresReload == false, "the first edit after a restart must patch, not reload");
		expect(Std.string(edit.changedFunctions) == Std.string(warm.changedFunctions),
			"the first edit after a restart must patch what a warm session patches: "
			+ Std.string(edit.changedFunctions)
			+ " against "
			+ Std.string(warm.changedFunctions));
		var next = build(restarted, 3);
		expect(next.moduleIdentity == first.moduleIdentity && next.patchAvailable == true && next.requiresReload == false,
			"edits after the first must keep patching");
		expect(restarted.recordLiveState(), "the resumed session must record its own publications");
		// History a resumed session recorded (its constant pools included) resumes again.
		var again = build(new CompilerSession(), 4);
		expect(again.moduleIdentity == first.moduleIdentity
			&& again.revision == next.revision + 1
			&& again.patchAvailable == true
			&& again.requiresReload == false,
			"history recorded by a resumed session must resume again");
		next = again;
		// A module the history does not describe (here, one whose marker names another revision) starts a new module.
		File.saveContent(output + ".live.full", next.moduleIdentity + ":" + Std.string(next.revision + 7));
		var stale = build(new CompilerSession(), 5);
		expect(stale.moduleIdentity != first.moduleIdentity, "history recorded for another module must not be resumed");
		for (path in FileSystem.readDirectory(root))
			FileSystem.deleteFile(root + "/" + path);
		FileSystem.deleteDirectory(root);
		Sys.println("PASS: a restarted live session patches the module the previous session published");
	}

	static function expect(condition:Bool, message:String):Void {
		if (!condition)
			throw message;
	}
}
