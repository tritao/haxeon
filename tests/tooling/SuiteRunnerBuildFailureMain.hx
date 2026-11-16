import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;
import tools.dev.SuiteRunner;

/** A failed native setup must make the gate itself fail, before running any suite. */
class SuiteRunnerBuildFailureMain {
	static function main():Void {
		var temp = Sys.getEnv("TMPDIR");
		if (temp == null || temp == "") throw "TMPDIR is required";
		var work = Path.join([temp, 'suite-build-failure-${Std.random(0x3fffffff)}']);
		FileSystem.createDirectory(work);
		try {
			check(work);
		} catch (error:Dynamic) {
			remove(work);
			throw error;
		}
		remove(work);
		Sys.println("PASS: a failed gate build returns a failure status");
	}

	static function check(work:String):Void {
		FileSystem.createDirectory(Path.join([work, "tests"]));
		FileSystem.createDirectory(Path.join([work, "scripts"]));
		File.saveContent(Path.join([work, "tests", "suites.txt"]), "dummy quick -- exit 0\n");
		var build = Path.join([work, "scripts", "build-native.sh"]);
		File.saveContent(build, "#!/bin/sh\nexit 73\n");
		if (Sys.command("chmod", ["+x", build]) != 0) throw "Cannot mark build fixture executable";
		if (Sys.command("git", ["init", "-q", work]) != 0) throw "Cannot initialize gate fixture";
		var status = SuiteRunner.run(work, {mode: "quick", jobs: 1, gate: true, only: []});
		if (status == 0) throw "Gate returned success after native setup failed";
		var gate = Path.join([work, "out", "gate"]), runs = FileSystem.readDirectory(gate);
		if (runs.length != 1) throw "Expected one gate report";
		var summary = File.getContent(Path.join([gate, runs[0], "summary.txt"]));
		if (summary.indexOf("build: FAILED") < 0 || summary.indexOf("exit: 1") < 0)
			throw "Gate report did not record the build failure";
	}

	static function remove(path:String):Void {
		if (!FileSystem.exists(path)) return;
		if (FileSystem.isDirectory(path)) {
			for (entry in FileSystem.readDirectory(path)) remove(Path.join([path, entry]));
			FileSystem.deleteDirectory(path);
		} else FileSystem.deleteFile(path);
	}
}
