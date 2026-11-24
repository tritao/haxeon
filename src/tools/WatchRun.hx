package tools;

import build.HaxeonProjectBuild;
import build.Target;
import build.execution.OutputCapture;
import compiler.core.InternalError;
import compiler.tools.Verbosity;
import haxe.Json;
import haxe.io.Path;
import project.PackageManifest;
import project.ResolvedProject;
import project.ShaderInputs;
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
	public static function run(initial:ResolvedProject, runtime:String, output:String, arguments:Array<String>,
			liveHost:Null<String>, entry:String,
			profiling:Null<WatchProfiling>, rebuild:WatchChange->Null<ResolvedProject>, verbosity:Verbosity,
			?session:build.BuildSession, runner:Bool = false, instrument:Bool = false):Int {
		if (Sys.systemName() != "Linux" && Sys.systemName() != "Mac" && Sys.systemName() != "Windows")
			throw new InternalError("haxeon run --watch currently requires Linux, macOS or Windows");
		// Each edit's result goes to the events file too, and the app (and a live host) learns its path from the environment.
		var events = WatchEvents.pathFor(output),
			rebuilds = 0;
		WatchEvents.reset(events);
		Sys.putEnv(WatchEvents.ENVIRONMENT, events);
		var project = initial,
			baseline = snapshot(project, null, instrument),
			logPath = output + ".watch.log",
			profile = startProfile(profiling),
			process = launch(runtime, output, arguments, project.root, logPath, liveHost, entry, profile, runner),
			logOffset = 0,
			result = 0;
		var watcher = openWatcher(project, baseline);
		if (verbosity.atLeast(Verbosity.Detailed))
			Sys.println(watcher == null
				? 'haxeon: polling every $POLL_SECONDS s' : 'haxeon: watching ${watcher.directories()} '
				+ 'directories (${DirectoryWatcher.BACKEND})');
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
				var observed = snapshot(project, null, instrument);
				if (same(baseline, observed)) {
					// Writes that are not edits (the app's log, build output) also notify; do not scan again for them at once.
					if (notified)
						Sys.sleep(NOTIFIED_IDLE_SECONDS);
					else if (session != null)
						// No save is pending and the sources are as the last build found them: what it left for later is done now.
						session.runIdleWork();
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
					observed = snapshot(project, null, instrument);
					if (same(baseline, observed))
						break;
					baseline = observed;
				}
				var change = classify(previous, baseline),
					compilerOnly = change.compilerOnly;
				Sys.println("haxeon: source changed; rebuilding" + (compilerOnly ? " Haxe code" : " project"));
				// `baseline` stays the snapshot this build started from: a save that lands while it runs differs from it, so the
				// next pass builds again. Snapshotting after the build would take such a save as built.
				var build = ++rebuilds;
				rotateEvents(events);
				WatchEvents.emit(events, "rebuild-started", build, null, null, changedPaths(previous, baseline));
				// The build's output streams into the events file as it prints: its console is not where anyone looks.
				// Lines are queued under the capture lock and appended in batches (WatchEventLines), all before the result event.
				var lines = new WatchEventLines(events, build);
				OutputCapture.begin(lines.add);
				var updated = try rebuild(change) catch (error:haxe.Exception) {
					OutputCapture.end();
					lines.close();
					throw error;
				}
				OutputCapture.end();
				lines.close();
				if (updated == null) {
					Sys.stderr().writeString("haxeon: build failed; keeping the current app open\n");
					WatchEvents.emit(events, "build-failed", build);
					continue;
				}
				// A project resolved again may watch other directories; an edit of Haxe contents keeps the same one.
				if (updated != project)
					watcher = reopenWatcher(watcher, updated, instrument);
				project = updated;
				var published = liveHost == null ? null : publication(output);
				WatchEvents.emit(events, "build-ok", build, published == null ? null : published.revision);
				if (liveHost != null && compilerOnly && published != null)
					WatchEvents.emit(events, "patch-published", build, published.revision, null, null,
						published.reloadReasons);
				if (liveHost != null && compilerOnly) {
					if (profile != null)
						profile.keepRevision(output);
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
				WatchEvents.emit(events, "reload", build, null, null, null, null, "restarting the app");
				process = launch(runtime, output, arguments, project.root, logPath, liveHost, entry, profile, runner);
				logOffset = 0;
			}
		} catch (error:haxe.Exception) {
			if (watcher != null)
				watcher.close();
			stop(process);
			finishProfile(profile);
			printLog(logPath, logOffset);
			throw error;
		}
		if (watcher != null)
			watcher.close();
		if (session != null)
			session.runIdleWork();
		process.close();
		finishProfile(profile);
		printLog(logPath, logOffset);
		return result;
	}

	/** Polling interval, which is also the longest an unwatched change waits to be noticed. */
	public static inline final POLL_SECONDS = 0.35;

	/** A save counts as finished once no notification has arrived for this long. */
	static inline final COALESCE_SECONDS = 0.03;

	static inline final MAX_COALESCE_SECONDS = 0.5;

	static inline final NOTIFIED_IDLE_SECONDS = 0.1;

	/** Returns once no notification has arrived for a moment. Bounded, so a tree that never goes quiet (an app logging under the root) still compiles. */
	public static function coalesce(watcher:DirectoryWatcher):Void {
		var quiet = Sys.time() + MAX_COALESCE_SECONDS;
		while (watcher.wait(COALESCE_SECONDS) && Sys.time() < quiet) {}
	}

	static function reopenWatcher(old:Null<DirectoryWatcher>, project:ResolvedProject,
			instrument:Bool):Null<DirectoryWatcher> {
		if (old != null)
			old.close();
		return openWatcher(project, snapshot(project, null, instrument));
	}

	/** Package roots are watched recursively; watched files outside every root (native sources elsewhere) by their directory. */
	public static function openWatcher(project:ResolvedProject, files:Map<String, String>):Null<DirectoryWatcher> {
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
		// The build's own output changes on every build and is never an edit.
		var output = project.manifest.outputDir;
		return DirectoryWatcher.create(directories,
			[Path.isAbsolute(output) ? output : Path.join([project.root, output])]);
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
		return profiling == null ? null : new ProfileCapture(profiling.profiler,
			ProfileCapture.nextCapture(profiling.root), profiling.processName,
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
		Empties the app's log before the next app starts. The shell's redirection truncates it too, but only once the new
		process runs: a read of the log before then would take the previous app's output for the new one's and skip as
		much of the new output. On Windows it also waits out the old app: taskkill /F returns before it has closed its
		handles, and while it still holds the log the new cmd.exe redirection fails and the relaunch exits at once.
	**/
	static function releaseLog(path:String):Void {
		var deadline = Sys.time() + 10.0;
		while (true) {
			try {
				File.saveContent(path, "");
				return;
			} catch (error:haxe.Exception) {
				if (Sys.time() > deadline)
					throw error;
				Sys.sleep(0.1);
			}
		}
	}

	static function launch(runtime:String, output:String, arguments:Array<String>, cwd:String, logPath:String,
			liveHost:Null<String>, entry:String,
			profile:Null<ProfileCapture>, runner:Bool):Process {
		var runtimeOptions = profile == null ? [] : profile.runtimeArguments();
		var program = liveHost == null ? [output].concat(arguments) : [
			liveHost,
			output,
			entry,
			Json.stringify(arguments)
		];
		// An app's runner (docs/design/PROJECT_BUILDS.md) runs the module it is given by its option, the rest as its arguments.
		if (runner)
			program = ["--haxeon-module=" + program[0]].concat(program.slice(1));
		var commandArguments = [runtime].concat(runtimeOptions).concat(program);
		var command = "exec " + commandArguments.map(quote).join(" ") + " > " + quote(logPath) + " 2>&1";
		// macOS strips DYLD_* from what the protected /bin/sh inherits, so the app would not find its native
		// libraries. Set the search path again inside the shell.
		var dyldPath = Sys.systemName() == "Mac" ? Sys.getEnv("DYLD_LIBRARY_PATH") : null;
		if (dyldPath != null && dyldPath.length > 0)
			command = "export DYLD_LIBRARY_PATH=" + quote(dyldPath) + "; " + command;
		// Without arguments, Process runs a Windows line through cmd /C, which supplies the outer quotes.
		var windowsCommand = commandArguments.map(windowsQuote).join(" ") + " > " + windowsQuote(logPath) + " 2>&1";
		releaseLog(logPath);
		var previous = Sys.getCwd();
		try {
			Sys.setCwd(cwd);
			if (profile != null)
				profile.keepBytecode(output);
			var process = Sys.systemName() == "Windows" ? new Process(windowsCommand) : new Process("/bin/sh", [
				"-c",
				command
			]);
			Sys.setCwd(previous);
			// The app waits on its diagnostics port until the recorder attaches.
			if (profile != null)
				profile.startRecorder();
			Sys.println('haxeon: running $output' + (profile == null ? "" : ' (profiling to ${profile.capture})'));
			// Tools that read the watch's output from a file wait for this line, and an app that prints nothing would leave
			// it in the buffer.
			Sys.stdout().flush();
			return process;
		} catch (error:haxe.Exception) {
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
		} catch (error:haxe.Exception) {
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
	public static function snapshot(project:ResolvedProject, ?target:Target,
			instrument:Bool = false):Map<String, String> {
		var result:Map<String, String> = [];
		for (item in project.packages.packages) {
			// Either manifest name, so a migration (one appearing, the other going) is a change too.
			for (name in [PackageManifest.TOML_NAME, PackageManifest.JSON_NAME])
				record(Path.join([item.root, name]), result);
			for (root in item.sourceRoots)
				collect(root, "hx", result);
			for (path in item.ffiInterfaces)
				record(path, result);
			for (path in item.ffiProjections)
				record(path, result);
			for (path in item.nativeSources)
				record(path, result);
			for (path in item.nativeCMakeInputs)
				record(path, result);
		}
		var shaderRoots = ShaderInputs.roots(project);
		if (shaderRoots.length > 0) {
			for (root in shaderRoots)
				collect(root, "glsl", result);
			var generated = ShaderInputs.output(HaxeonProjectBuild.outputDirectory(project, instrument),
				target == null ? Target.detectHost() : target);
			var dependencies = ShaderInputs.dependencies(generated);
			if (FileSystem.exists(dependencies))
				for (line in File.getContent(dependencies).split("\n"))
					if (line != "")
						record(line, result);
		}
		return result;
	}

	/** Records `path` if it is a file; a missing path or a directory is left out. */
	static function record(path:String, result:Map<String, String>):Void {
		var stat = statOrNull(path);
		if (stat != null && !isDirectory(stat))
			result.set(path, signature(path, stat));
	}

	static function collect(root:String, extension:String, result:Map<String, String>):Void {
		var stat = statOrNull(root);
		if (stat == null)
			return;
		if (!isDirectory(stat)) {
			if (Path.extension(root) == extension)
				result.set(root, signature(root, stat));
			return;
		}
		for (name in FileSystem.readDirectory(root)) {
			var path = Path.join([root, name]), entry = statOrNull(path);
			if (entry == null)
				continue;
			if (isDirectory(entry))
				collect(path, extension, result);
			else if (Path.extension(path) == extension)
				result.set(path, signature(path, entry));
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

	/**
		A file's modification time and size, and for a file modified in the last `RACY_SECONDS` its content's digest too (`sameFile`).
		The time has a resolution of one second, so a save of the same size within the second of the one before it (one digit for
		another) would otherwise look unchanged and never be built.
	**/
	static function signature(path:String, stat:sys.FileStat):String {
		var modified = stat.mtime.getTime(), text = '$modified:${stat.size}';
		if (Date.now().getTime() - modified >= RACY_SECONDS * 1000.0)
			return text;
		var digest = digestOrNull(path);
		return digest == null ? text : text + ":" + digest;
	}

	static inline final RACY_SECONDS = 2.0;

	static function digestOrNull(path:String):Null<String> {
		try {
			return build.execution.ContentDigest.makeHex(File.getBytes(path));
		} catch (_:Dynamic) {
			return null;
		}
	}

	/**
		Whether the file at `path` is unchanged from its signature in an earlier snapshot (`before`) to a later one (`after`). With
		the same time and size, an earlier signature without a digest was taken once no write could share that time any more, so the
		file is unchanged; one with a digest is compared with the later digest, or with the file's when the later has none.
	**/
	static function sameFile(path:String, before:Null<String>, after:Null<String>):Bool {
		if (before == after)
			return true;
		if (before == null || after == null)
			return false;
		var earlier = before.split(":"), later = after.split(":");
		if (earlier[0] != later[0] || earlier[1] != later[1])
			return false;
		if (earlier.length < 3)
			return true;
		return earlier[2] == (later.length < 3 ? digestOrNull(path) : later[2]);
	}

	public static function same(a:Map<String, String>, b:Map<String, String>):Bool {
		for (path in a.keys())
			if (!sameFile(path, a.get(path), b.get(path)))
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
			if (!sameFile(path, before.get(path), after.get(path)) && Path.extension(path) != "hx")
				return false;
		for (path in after.keys())
			if (!before.exists(path) && Path.extension(path) != "hx")
				return false;
		return true;
	}

	/** Moves a file that grew past `WatchEvents.MAX_BYTES` to `<file>.1`, so a long session keeps the recent events and a bounded file. */
	static function rotateEvents(path:String):Void {
		try {
			if (!FileSystem.exists(path) || FileSystem.stat(path).size < WatchEvents.MAX_BYTES)
				return;
			var previous = path + ".1";
			if (FileSystem.exists(previous))
				FileSystem.deleteFile(previous);
			FileSystem.rename(path, previous);
		} catch (_:Dynamic) {
			WatchEvents.reset(path);
		}
	}

	/** Paths that differ between two watch snapshots, sorted. */
	static function changedPaths(before:Map<String, String>, after:Map<String, String>):Array<String> {
		var result:Array<String> = [];
		for (path in after.keys())
			if (!sameFile(path, before.get(path), after.get(path)))
				result.push(path);
		for (path in before.keys())
			if (!after.exists(path))
				result.push(path);
		result.sort(Reflect.compare);
		return result;
	}

	/** The revision and reload reasons of the live publication the compiler just wrote, or null without one. */
	static function publication(output:String):Null<{revision:Int, reloadReasons:Array<String>}> {
		try {
			var value:Dynamic = Json.parse(File.getContent(output + ".live.patch.json"));
			if (!Std.isOfType(value.revision, Int))
				return null;
			var reasons:Null<Array<Dynamic>> = value.reloadReasons;
			function describe(reason:Dynamic):String {
				if (reason.code == null)
					return Std.string(reason);
				return reason.entityId == null ? Std.string(reason.code) : Std.string(reason.code) + " "
					+ Std.string(reason.entityId);
			}
			var described = reasons == null ? [] : [for (reason in reasons) describe(reason)];
			if (value.requiresReload == true && described.length == 0)
				described.push("the build requires a reload");
			return {revision: (value.revision: Int), reloadReasons: described};
		} catch (_:Dynamic) {
			return null;
		}
	}
}
