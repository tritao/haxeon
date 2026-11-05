import build.RuntimeBuildSafety;
import build.execution.ContentDigest;
import haxe.io.Bytes;
import haxe.io.Path;

/** Exercises the mapped-library check while this HashLink process keeps its runtime loaded. */
class RuntimeBuildSafetyProbe {
	static function main():Void {
		var args = Sys.args(), output = args[0], mode = args[1], source = args[2],
			before = ContentDigest.makeHex(Bytes.ofString("runtime isolation")),
			conflict = RuntimeBuildSafety.conflictingLibrary(output);
		if (mode == "conflict") {
			if (conflict == null || Path.withoutDirectory(conflict) != "haxeon_runtime.hdll")
				throw 'Expected the loaded runtime in $output, got $conflict';
			Sys.println('PASS: loaded runtime detected: $conflict');
			return;
		}
		if (conflict != null)
			throw 'A separately loaded runtime was rejected: $conflict';
		var status = Sys.command("cc", ["-shared", "-fPIC", "-o", Path.join([output, "haxeon_runtime.hdll"]), source]);
		if (status != 0)
			throw 'Native rebuild failed: $status';
		if (ContentDigest.makeHex(Bytes.ofString("runtime isolation")) != before)
			throw "The loaded runtime changed during the separate build";
		Sys.println("PASS: rebuilding a separate output leaves the loaded runtime usable");
	}
}
