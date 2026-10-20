package tools;

import haxe.io.Path;
import haxe.Json;
import project.ResolvedProject;
import sys.FileSystem;
import sys.io.File;
import sys.io.Process;

/** Host edit loop for a resolved Haxeon project. A failed build keeps the live process. */
class WatchRun {
	public static function run(initial:ResolvedProject, runtime:String, output:String, arguments:Array<String>, liveHost:Null<String>, entry:String,
			rebuild:Bool->Null<ResolvedProject>):Int {
		if (Sys.systemName() != "Linux" && Sys.systemName() != "Mac" && Sys.systemName() != "Windows")
			throw "haxeon run --watch currently requires Linux, macOS or Windows";
		var project = initial, baseline = snapshot(project), logPath = output + ".watch.log",
			process = launch(runtime, output, arguments, project.root, logPath, liveHost, entry), logOffset = 0, result = 0;
		try {
			while (true) {
				Sys.sleep(0.35);
				logOffset = printLog(logPath, logOffset);
				var status = process.exitCode(false);
				if (status != null) {
					result = status;
					break;
				}
				var observed = snapshot(project);
				if (same(baseline, observed))
					continue;
				var previous = baseline;
				baseline = observed;
				while (true) {
					Sys.sleep(0.5);
					observed = snapshot(project);
					if (same(baseline, observed))
						break;
					baseline = observed;
				}
				var compilerOnly = haxeOnly(previous, baseline);
				Sys.println("haxeon: source changed; rebuilding" + (compilerOnly ? " Haxe code" : " project"));
				var updated = rebuild(compilerOnly);
				if (updated == null) {
					Sys.stderr().writeString("haxeon: build failed; keeping the current app open\n");
					baseline = snapshot(project);
					continue;
				}
				project = updated;
				if (liveHost != null && compilerOnly) {
					baseline = snapshot(project);
					continue;
				}
				logOffset = printLog(logPath, logOffset);
				var exited = process.exitCode(false);
				if (exited != null) {
					result = exited;
					break;
				}
				kill(process);
				process.exitCode();
				process.close();
				process = launch(runtime, output, arguments, project.root, logPath, liveHost, entry);
				logOffset = 0;
				baseline = snapshot(project);
			}
		} catch (error:Dynamic) {
			stop(process);
			printLog(logPath, logOffset);
			throw error;
		}
		process.close();
		printLog(logPath, logOffset);
		return result;
	}

	static function stop(process:Process):Void {
		if (process.exitCode(false) == null)
			kill(process);
		process.exitCode();
		process.close();
	}

	/** On Windows the app runs under cmd.exe, so the whole tree must be stopped. */
	static function kill(process:Process):Void {
		if (Sys.systemName() == "Windows") {
			// Captured: taskkill reports every descendant, including ones already exiting.
			var taskkill = new Process("taskkill", ["/T", "/F", "/PID", Std.string(process.getPid())]);
			taskkill.exitCode();
			taskkill.close();
		} else
			process.kill();
	}

	/**
		taskkill /F returns before the old app has closed its handles. While it still holds the
		log, the new cmd.exe redirection fails and the relaunch exits at once.
	**/
	static function releaseLog(path:String):Void {
		var deadline = Sys.time() + 10.0;
		while (true) {
			try {
				File.saveContent(path, "");
				return;
			} catch (error:Dynamic) {
				if (Sys.time() > deadline) throw error;
				Sys.sleep(0.1);
			}
		}
	}

	static function launch(runtime:String, output:String, arguments:Array<String>, cwd:String, logPath:String, liveHost:Null<String>, entry:String):Process {
		var commandArguments = liveHost == null ? [runtime, output].concat(arguments) : [runtime, liveHost, output, entry, Json.stringify(arguments)];
		var command = "exec " + commandArguments.map(quote).join(" ") + " > " + quote(logPath) + " 2>&1";
		// Without arguments, Process runs a Windows line through cmd /C, which supplies the outer quotes.
		var windowsCommand = commandArguments.map(windowsQuote).join(" ") + " > " + windowsQuote(logPath) + " 2>&1";
		if (Sys.systemName() == "Windows") releaseLog(logPath);
		var previous = Sys.getCwd();
		try {
			Sys.setCwd(cwd);
			var process = Sys.systemName() == "Windows" ? new Process(windowsCommand) : new Process("/bin/sh", ["-c", command]);
			Sys.setCwd(previous);
			Sys.println('haxeon: running $output');
			return process;
		} catch (error:Dynamic) {
			Sys.setCwd(previous);
			throw error;
		}
	}

	static function quote(value:String):String
		return "'" + value.split("'").join("'\\''") + "'";

	static function windowsQuote(value:String):String
		return '"' + value.split('"').join('\\"') + '"';

	static function printLog(path:String, offset:Int):Int {
		if (!FileSystem.exists(path))
			return offset;
		var size = Std.int(FileSystem.stat(path).size);
		if (size <= offset)
			return size;
		var input = File.read(path);
		try {
			input.seek(offset, sys.io.FileSeek.SeekBegin);
			Sys.stdout().writeString(input.readString(size - offset));
			Sys.stdout().flush();
		} catch (error:Dynamic) {
			input.close();
			throw error;
		}
		input.close();
		return size;
	}

	static function snapshot(project:ResolvedProject):Map<String, String> {
		var files:Map<String, Bool> = [];
		for (item in project.packages.packages) {
			files.set(Path.join([item.root, "haxeon.json"]), true);
			for (root in item.sourceRoots)
				collect(root, files);
			for (path in item.ffiInterfaces)
				files.set(path, true);
			for (path in item.ffiProjections)
				files.set(path, true);
			for (path in item.nativeSources)
				files.set(path, true);
			for (path in item.nativeCMakeInputs)
				files.set(path, true);
		}
		var result:Map<String, String> = [];
		for (path in files.keys())
			if (FileSystem.exists(path) && !FileSystem.isDirectory(path)) {
				var stat = FileSystem.stat(path);
				result.set(path, '${stat.mtime.getTime()}:${stat.size}');
			}
		return result;
	}

	static function collect(root:String, files:Map<String, Bool>):Void {
		if (!FileSystem.exists(root))
			return;
		if (!FileSystem.isDirectory(root)) {
			if (Path.extension(root) == "hx")
				files.set(root, true);
			return;
		}
		for (name in FileSystem.readDirectory(root)) {
			var path = Path.join([root, name]);
			if (FileSystem.isDirectory(path))
				collect(path, files);
			else if (Path.extension(path) == "hx")
				files.set(path, true);
		}
	}

	static function same(a:Map<String, String>, b:Map<String, String>):Bool {
		for (path in a.keys())
			if (a.get(path) != b.get(path))
				return false;
		for (path in b.keys())
			if (!a.exists(path))
				return false;
		return true;
	}

	static function haxeOnly(before:Map<String, String>, after:Map<String, String>):Bool {
		for (path in before.keys())
			if (before.get(path) != after.get(path) && Path.extension(path) != "hx")
				return false;
		for (path in after.keys())
			if (!before.exists(path) && Path.extension(path) != "hx")
				return false;
		return true;
	}
}
