package tools;

import haxe.io.Path;
import haxe.Json;
import project.ResolvedProject;
import sys.FileSystem;
import sys.io.File;
import sys.io.Process;

/** Profiles every launch of a watched app into its own capture under root. */
typedef WatchProfiling = {
	final profiler:String;
	final root:String;
	final processName:String;
	final sources:Array<String>;
}

/** What a settled batch of edits touched, which decides how much of the build can be reused. */
typedef WatchChange = {
	/** Only Haxe sources changed, so the native packages need no rebuild. */
	final compilerOnly:Bool;

	/** The set of watched files changed, or one that is not Haxe: the resolved project may differ and must be resolved again. */
	final structural:Bool;
}

/** Host edit loop for a resolved Haxeon project. A failed build keeps the live process. */
class WatchRun {
	public static function run(initial:ResolvedProject, runtime:String, output:String, arguments:Array<String>, liveHost:Null<String>, entry:String,
			profiling:Null<WatchProfiling>, rebuild:WatchChange->Null<ResolvedProject>, ?session:build.BuildSession):Int {
		if (Sys.systemName() != "Linux" && Sys.systemName() != "Mac" && Sys.systemName() != "Windows")
			throw "haxeon run --watch currently requires Linux, macOS or Windows";
		var project = initial, baseline = snapshot(project), logPath = output + ".watch.log", profile = startProfile(profiling),
			process = launch(runtime, output, arguments, project.root, logPath, liveHost, entry, profile), logOffset = 0, result = 0;
		var watcher = openWatcher(project, baseline);
		try {
			while (true) {
				// A notification wakes the loop at once; the timeout is the poll that backs it up, covering anything not watched.
				var notified = watcher != null && watcher.wait(POLL_SECONDS);
				if (watcher == null)
					Sys.sleep(POLL_SECONDS);
				logOffset = printLog(logPath, logOffset);
				// The compiler worker would otherwise exit during a long pause, and the next edit would compile cold.
				if (session != null)
					session.keepWorkersAlive();
				var status = process.exitCode(false);
				if (status != null) {
					result = status;
					break;
				}
				// The app waits on its diagnostics port until the recorder resumes it, so a recorder that failed would leave it held.
				var recorderStatus = profile == null ? null : profile.recorderFailure();
				if (recorderStatus != null) {
					Sys.stderr()
						.writeString('haxeon: the profiler stopped while the app was running (status $recorderStatus); stopping the app. See ${profile.recorderLog()}\n');
					kill(process);
					process.exitCode();
					result = 1;
					break;
				}
				// Scan once the save has finished, not halfway through it and then again.
				if (notified)
					coalesce(watcher);
				var observed = snapshot(project);
				if (same(baseline, observed)) {
					// Writes that are not edits (the app's log, build output) also notify; do not scan again for them at once.
					if (notified)
						Sys.sleep(NOTIFIED_IDLE_SECONDS);
					continue;
				}
				var previous = baseline;
				baseline = observed;
				while (true) {
					// With notifications the scan saw a finished save unless one arrived while it ran; otherwise wait out a polling
					// interval and compare again.
					if (watcher != null) {
						if (!watcher.wait(0))
							break;
						coalesce(watcher);
					} else
						Sys.sleep(0.5);
					observed = snapshot(project);
					if (same(baseline, observed))
						break;
					baseline = observed;
				}
				var change = classify(previous, baseline),
					compilerOnly = change.compilerOnly;
				Sys.println("haxeon: source changed; rebuilding" + (compilerOnly ? " Haxe code" : " project"));
				var updated = rebuild(change);
				if (updated == null) {
					Sys.stderr().writeString("haxeon: build failed; keeping the current app open\n");
					baseline = snapshot(project);
					continue;
				}
				project = updated;
				watcher = reopenWatcher(watcher, project);
				if (liveHost != null && compilerOnly) {
					if (profile != null)
						profile.keepRevision(output);
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
				finishProfile(profile);
				profile = startProfile(profiling);
				process = launch(runtime, output, arguments, project.root, logPath, liveHost, entry, profile);
				logOffset = 0;
				baseline = snapshot(project);
			}
		} catch (error:Dynamic) {
			if (watcher != null)
				watcher.close();
			stop(process);
			finishProfile(profile);
			printLog(logPath, logOffset);
			throw error;
		}
		if (watcher != null)
			watcher.close();
		process.close();
		finishProfile(profile);
		printLog(logPath, logOffset);
		return result;
	}

	/** Polling interval, which is also the longest an unwatched change waits to be noticed. */
	static inline final POLL_SECONDS = 0.35;

	/** A save counts as finished once no notification has arrived for this long. */
	static inline final COALESCE_SECONDS = 0.03;

	static inline final MAX_COALESCE_SECONDS = 0.5;

	static inline final NOTIFIED_IDLE_SECONDS = 0.1;

	/** Returns once no notification has arrived for a moment. Bounded, so a tree that never goes quiet (an app logging under the root) still compiles. */
	static function coalesce(watcher:DirectoryWatcher):Void {
		var quiet = Sys.time() + MAX_COALESCE_SECONDS;
		while (watcher.wait(COALESCE_SECONDS) && Sys.time() < quiet) {}
	}

	static function reopenWatcher(old:Null<DirectoryWatcher>, project:ResolvedProject):Null<DirectoryWatcher> {
		if (old != null)
			old.close();
		return openWatcher(project, snapshot(project));
	}

	/** Package roots are watched recursively; watched files outside every root (native sources elsewhere) by their directory. */
	static function openWatcher(project:ResolvedProject, files:Map<String, String>):Null<DirectoryWatcher> {
		var directories:Array<{path:String, recursive:Bool}> = [],
			roots:Array<String> = [];
		for (item in project.packages.packages) {
			var root = normalize(item.root), covered = false;
			for (other in roots)
				if (within(other, root))
					covered = true;
			if (covered)
				continue;
			roots = roots.filter(other -> !within(root, other));
			directories = directories.filter(directory -> !within(root, normalize(directory.path)));
			roots.push(root);
			directories.push({path: item.root, recursive: true});
		}
		var loose:Map<String, Bool> = [];
		for (path in files.keys()) {
			var directory = Path.directory(path), key = normalize(directory);
			var covered = false;
			for (root in roots)
				if (within(root, key))
					covered = true;
			if (!covered && !loose.exists(key)) {
				loose.set(key, true);
				directories.push({path: directory, recursive: false});
			}
		}
		return DirectoryWatcher.create(directories);
	}

	static function normalize(path:String):String {
		var result = path.split("\\").join("/");
		while (result.length > 1 && StringTools.endsWith(result, "/"))
			result = result.substr(0, result.length - 1);
		return Sys.systemName() == "Windows" ? result.toLowerCase() : result;
	}

	static function within(parent:String, child:String):Bool
		return child == parent || StringTools.startsWith(child, parent + "/");

	static function startProfile(profiling:Null<WatchProfiling>):Null<ProfileCapture>
		return profiling == null ? null : new ProfileCapture(profiling.profiler, ProfileCapture.nextCapture(profiling.root), profiling.processName,
			profiling.sources);

	/** Called once the launch has exited: the recorder then finalizes its capture. */
	static function finishProfile(profile:Null<ProfileCapture>):Void {
		if (profile == null)
			return;
		var trace = profile.finishRecorder();
		if (trace != null)
			Sys.println('haxeon: profile written to $trace (open it at https://ui.perfetto.dev)');
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
				if (Sys.time() > deadline)
					throw error;
				Sys.sleep(0.1);
			}
		}
	}

	static function launch(runtime:String, output:String, arguments:Array<String>, cwd:String, logPath:String, liveHost:Null<String>, entry:String,
			profile:Null<ProfileCapture>):Process {
		var runtimeOptions = profile == null ? [] : profile.runtimeArguments();
		var commandArguments = [runtime].concat(runtimeOptions)
			.concat(liveHost == null ? [output].concat(arguments) : [liveHost, output, entry, Json.stringify(arguments)]);
		var command = "exec " + commandArguments.map(quote).join(" ") + " > " + quote(logPath) + " 2>&1";
		// Without arguments, Process runs a Windows line through cmd /C, which supplies the outer quotes.
		var windowsCommand = commandArguments.map(windowsQuote).join(" ") + " > " + windowsQuote(logPath) + " 2>&1";
		if (Sys.systemName() == "Windows")
			releaseLog(logPath);
		var previous = Sys.getCwd();
		try {
			Sys.setCwd(cwd);
			if (profile != null)
				profile.keepBytecode(output);
			var process = Sys.systemName() == "Windows" ? new Process(windowsCommand) : new Process("/bin/sh", ["-c", command]);
			Sys.setCwd(previous);
			// The app waits on its diagnostics port until the recorder attaches.
			if (profile != null)
				profile.startRecorder();
			Sys.println('haxeon: running $output' + (profile == null ? "" : ' (profiling to ${profile.capture})'));
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

	/**
		Each watched file's modification time and size. One stat per file: the same scan with `exists` and `isDirectory`
		before each stat made four calls per file and took ~105 ms for the editor's 1,224 files, twice per save.
	**/
	static function snapshot(project:ResolvedProject):Map<String, String> {
		var result:Map<String, String> = [];
		for (item in project.packages.packages) {
			record(Path.join([item.root, "haxeon.json"]), result);
			for (root in item.sourceRoots)
				collect(root, result);
			for (path in item.ffiInterfaces)
				record(path, result);
			for (path in item.ffiProjections)
				record(path, result);
			for (path in item.nativeSources)
				record(path, result);
			for (path in item.nativeCMakeInputs)
				record(path, result);
		}
		return result;
	}

	/** Records `path` if it is a file; a missing path or a directory is left out. */
	static function record(path:String, result:Map<String, String>):Void {
		var stat = statOrNull(path);
		if (stat != null && !isDirectory(stat))
			result.set(path, signature(stat));
	}

	static function collect(root:String, result:Map<String, String>):Void {
		var stat = statOrNull(root);
		if (stat == null)
			return;
		if (!isDirectory(stat)) {
			if (Path.extension(root) == "hx")
				result.set(root, signature(stat));
			return;
		}
		for (name in FileSystem.readDirectory(root)) {
			var path = Path.join([root, name]), entry = statOrNull(path);
			if (entry == null)
				continue;
			if (isDirectory(entry))
				collect(path, result);
			else if (Path.extension(path) == "hx")
				result.set(path, signature(entry));
		}
	}

	/** Null for a path that does not exist (or vanished since its directory was listed). */
	static function statOrNull(path:String):Null<sys.FileStat> {
		try {
			return FileSystem.stat(path);
		} catch (_:Dynamic) {
			return null;
		}
	}

	static inline function isDirectory(stat:sys.FileStat):Bool
		return (stat.mode & 0xF000) == 0x4000;

	static inline function signature(stat:sys.FileStat):String
		return '${stat.mtime.getTime()}:${stat.size}';

	static function same(a:Map<String, String>, b:Map<String, String>):Bool {
		for (path in a.keys())
			if (a.get(path) != b.get(path))
				return false;
		for (path in b.keys())
			if (!a.exists(path))
				return false;
		return true;
	}

	/** Resolution reads manifests and the files under the source roots, so editing a Haxe file's contents cannot change its result. */
	public static function classify(before:Map<String, String>, after:Map<String, String>):WatchChange {
		var compilerOnly = haxeOnly(before, after), structural = !compilerOnly;
		if (!structural) {
			for (path in before.keys())
				if (!after.exists(path))
					structural = true;
			for (path in after.keys())
				if (!before.exists(path))
					structural = true;
		}
		return {compilerOnly: compilerOnly, structural: structural};
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
