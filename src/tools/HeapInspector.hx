package tools;

import haxe.Json;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;
import sys.io.Process;

/** Runs the vendored HashLink heap analyzer on a bytecode/dump pair. */
class HeapInspector {
	public static function run(arguments:Array<String>):Int {
		if (arguments.length == 0 || arguments.shift() != "inspect")
			throw "Usage: haxeon heap inspect BYTECODE DUMP [--report PATH] | --capture DIR";
		var paths:Array<String> = [],
			report:Null<String> = null,
			capture:Null<String> = null;
		while (arguments.length > 0) {
			var argument = arguments.shift();
			switch argument {
				case "--report":
					if (arguments.length == 0)
						throw "--report requires a path";
					report = arguments.shift();
				case "--capture":
					if (arguments.length == 0)
						throw "--capture requires a directory";
					capture = arguments.shift();
				case _:
					if (StringTools.startsWith(argument, "-"))
						throw 'Unknown heap option "$argument"';
					paths.push(argument);
			}
		}
		if (capture != null) {
			if (paths.length != 0)
				throw "Use --capture or BYTECODE DUMP";
			var directory = FileSystem.fullPath(capture),
				manifestPath = Path.join([directory, "capture.json"]);
			if (!FileSystem.exists(manifestPath))
				throw 'Capture manifest is missing: $manifestPath';
			var manifest:Dynamic = Json.parse(File.getContent(manifestPath));
			if (Reflect.field(manifest, "kind") != "haxeon.capture" || Reflect.field(manifest, "schemaVersion") != 1)
				throw "Unsupported capture manifest";
			var artifacts:Dynamic = Reflect.field(manifest, "artifacts");
			paths = [
				captureArtifact(directory, artifacts, "bytecode"),
				captureArtifact(directory, artifacts, "heap")
			];
		}
		if (paths.length != 2)
			throw "Usage: haxeon heap inspect BYTECODE DUMP [--report PATH] | --capture DIR";
		var bytecode = FileSystem.fullPath(paths[0]),
			dump = FileSystem.fullPath(paths[1]);
		var home = Sys.getEnv("HAXEON_HOME");
		if (home == null || home == "")
			throw "HAXEON_HOME is missing";
		var haxe = Path.join([home, ".tools", "haxe", "haxe"]),
			hl = Path.join([home, ".tools", "hashlink", "hl"]),
			hlmem = Path.join([home, "vendor", "hashlink", "other", "haxelib"]),
			format = Path.join([home, "vendor", "format"]);
		for (file in [
			bytecode,
			dump,
			haxe,
			hl,
			Path.join([hlmem, "hlmem", "Main.hx"]),
			Path.join([format, "format", "hl", "Reader.hx"])
		])
			if (!FileSystem.exists(file) || FileSystem.isDirectory(file))
				throw 'Heap inspection input is missing: $file';
		var reportPath = report == null ? Path.join([Path.directory(dump), "heap-report.txt"]) : FileSystem.fullPath(report);
		var scratch = Path.join([
			Sys.getEnv("TMPDIR") == null ? "/tmp" : Sys.getEnv("TMPDIR"),
			"haxeon-hlmem-" + Std.random(0x7fffffff)
		]);
		FileSystem.createDirectory(scratch);
		var analyzer = Path.join([scratch, "hlmem.hl"]);
		var status = 1;
		try {
			status = inspect(haxe, hl, hlmem, format, home, analyzer, bytecode, dump, reportPath);
		} catch (error:Dynamic) {
			cleanup(scratch, analyzer);
			throw error;
		}
		cleanup(scratch, analyzer);
		return status;
	}

	static function inspect(haxe:String, hl:String, hlmem:String, format:String, home:String, analyzer:String, bytecode:String, dump:String,
			reportPath:String):Int {
		var compile = build.execution.ProcessRunner.run(haxe, ["-cp", hlmem, "-cp", format, "-main", "hlmem.Main", "-hl", analyzer], home, new Map());
		if (compile != 0)
			return compile;
		var process = new Process(hl, [analyzer, bytecode, dump, "--no-color", "--args", "stats", "types", "quit"]);
		var output = process.stdout.readAll().toString() + process.stderr.readAll().toString();
		var status = process.exitCode();
		process.close();
		ensureDirectory(Path.directory(reportPath));
		File.saveContent(reportPath, output);
		if (status != 0) {
			Sys.stderr().writeString('Heap inspection failed; see $reportPath\n');
			return status;
		}
		for (line in output.split("\n"))
			if (line.indexOf("live blocks") >= 0 || line.indexOf("unresolved type") >= 0)
				Sys.println(line);
		Sys.println('report=$reportPath');
		return 0;
	}

	static function cleanup(scratch:String, analyzer:String):Void {
		if (FileSystem.exists(analyzer))
			FileSystem.deleteFile(analyzer);
		if (FileSystem.exists(scratch))
			FileSystem.deleteDirectory(scratch);
	}

	static function captureArtifact(directory:String, artifacts:Dynamic, name:String):String {
		if (artifacts == null)
			throw "Capture manifest has no artifacts";
		var relative:Dynamic = Reflect.field(artifacts, name);
		if (!Std.isOfType(relative, String) || relative == "" || Path.isAbsolute(relative) || relative.indexOf("..") >= 0)
			throw 'Capture manifest has no valid $name artifact';
		return Path.join([directory, relative]);
	}

	static function ensureDirectory(directory:String):Void {
		if (FileSystem.exists(directory))
			return;
		ensureDirectory(Path.directory(directory));
		FileSystem.createDirectory(directory);
	}
}
