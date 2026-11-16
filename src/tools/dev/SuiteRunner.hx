package tools.dev;

import haxe.io.Bytes;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;
import sys.io.FileOutput;
import sys.io.Process;
import sys.thread.Lock;
import sys.thread.Mutex;
import sys.thread.Thread;
import tools.dev.SuiteManifest.Suite;

typedef SuiteRunOptions = {
	final mode:String;
	final jobs:Int;

	/** Gate mode: refuse a dirty tree (unless GATE_ALLOW_DIRTY=1), write to out/gate/<commit>-<mode>-<time>, log instead of streaming. */
	final gate:Bool;

	/** Run only these suites of the mode, when not empty. */
	final only:Array<String>;
}

private typedef SuiteResult = {
	final suite:Suite;

	/** Null when the suite was skipped. */
	final status:Null<Int>;

	final seconds:Int;
	final skipReason:Null<String>;
	final log:String;
}

/**
 * Runs a mode of tests/suites.txt: one native build and one resolution of the prebuilt tools, then every selected suite in list
 * order, lanes in the background and pools at once (see the manifest's header). A failing suite never stops the run; the exit code is
 * 0 only when every suite that ran passed. Each suite has a log in the run directory, and summary.txt there has one line per suite,
 * in the format gate reports quote.
 */
class SuiteRunner {
	static inline final POOL_LIMIT = 6;
	static inline final KEPT_RUNS = 5;

	final home:String;
	final options:SuiteRunOptions;
	final directory:String;
	final summary:FileOutput;
	final summaryMutex = new Mutex();
	final consoleMutex = new Mutex();
	final launchMutex = new Mutex();
	final started = Sys.time();
	var failed = false;
	var launcherActive = false;
	var haveWasmtime:Null<Bool> = null;

	function new(home:String, options:SuiteRunOptions, directory:String) {
		this.home = home;
		this.options = options;
		this.directory = directory;
		ensureDirectory(directory);
		summary = File.write(Path.join([directory, "summary.txt"]));
	}

	public static function run(home:String, options:SuiteRunOptions):Int {
		var suites = SuiteManifest.select(SuiteManifest.parse(Path.join([home, "tests", "suites.txt"])), options.mode);
		if (options.only.length > 0) {
			for (name in options.only)
				if (suites.filter(suite -> suite.name == name).length == 0)
					throw 'Suite "$name" is not in mode ${options.mode}';
			suites = suites.filter(suite -> options.only.indexOf(suite.name) >= 0);
		}
		var stamp = DateTools.format(Date.now(), "%Y%m%d-%H%M%S"),
			commit = git(home, ["rev-parse", "--short=8", "HEAD"]),
			state = "clean";
		if (StringTools.trim(git(home, ["status", "--porcelain", "--untracked-files=no"])) != "") {
			if (options.gate && Sys.getEnv("GATE_ALLOW_DIRTY") != "1") {
				Sys.stderr().writeString("gate: the tracked tree has changes; commit them or set GATE_ALLOW_DIRTY=1\n");
				Sys.stderr().writeString(git(home, ["status", "--short", "--untracked-files=no"]));
				return 2;
			}
			state = "dirty";
		}
		var root = Path.join([home, "out", options.gate ? "gate" : "test"]),
			directory = Path.join([root, options.gate ? '$commit-${options.mode}-$stamp' : '$stamp-${options.mode}']);
		if (!options.gate)
			pruneRuns(root);
		return new SuiteRunner(home, options, directory).execute(suites, commit, state);
	}

	/** The suites a mode runs, one per line, with their scheduling. */
	public static function list(home:String, mode:String):Int {
		for (suite in SuiteManifest.select(SuiteManifest.parse(Path.join([home, "tests", "suites.txt"])), mode)) {
			var placement = suite.lane != null ? ' lane=${suite.lane}' : suite.pool != null
				? ' pool=${suite.pool}' : "";
			Sys.println('${suite.name}$placement${suite.requires.length > 0 ? " requires=" + suite.requires.join(",") : ""}');
		}
		return 0;
	}

	function execute(suites:Array<Suite>, commit:String, state:String):Int {
		record('commit: $commit ($state) branch: ${git(home, ["branch", "--show-current"])}');
		record('mode: ${options.mode} jobs: ${options.jobs}');
		record('date: ${DateTools.format(Date.now(), "%Y-%m-%dT%H:%M:%S")} load at start: ${load()} cores: ${cores()}');
		console('${prefix()}${suites.length} suites; logs in $directory');
		if (!setUp()) {
			record("build: FAILED (see build-*.log)");
			return finish();
		}
		record("build: ok");

		var lanes:Array<{lock:Lock, results:Array<SuiteResult>}> = [],
			startedLanes = new Map<String, Bool>(),
			index = 0;
		while (index < suites.length) {
			var suite = suites[index];
			if (suite.lane != null) {
				if (!startedLanes.exists(suite.lane)) {
					startedLanes.set(suite.lane, true);
					lanes.push(startLane(suites.filter(member -> member.lane == suite.lane)));
				}
				index++;
			} else if (suite.pool != null) {
				var end = index;
				while (end < suites.length && suites[end].pool == suite.pool)
					end++;
				runPool(suites.slice(index, end));
				index = end;
			} else {
				runOne(suite, !options.gate);
				index++;
			}
		}
		for (lane in lanes) {
			lane.lock.wait();
			for (result in lane.results)
				printLog(result);
		}
		return finish();
	}

	/** The native runtime, then the prebuilt tools, pinned in the environment for every suite. */
	function setUp():Bool {
		var nativeLog = Path.join([directory, "build-native.log"]);
		console('${prefix()}building the native runtime and the prebuilt tools');
		if (runScript('cd ${quote(home)} || exit 2\nscripts/build-native.sh', nativeLog, false) != 0) {
			console(File.getContent(nativeLog));
			return false;
		}
		var artifacts = new ToolArtifacts(home),
			pins = [
				{variable: "HAXEON_MAIN_HL", main: "Main"},
				{variable: "HAXEON_COMPILER_HL", main: "compiler.tools.HaxeonCompiler"},
				{variable: "HAXEON_BUILD_HL", main: "build.HaxeonBuild"},
				{variable: "HAXEON_TEST_CLI_HL", main: "tools.HaxeonCli"}
			],
			resolved = new Map<String, String>(),
			errors = [],
			done = new Lock(),
			mutex = new Mutex();
		for (pin in pins) {
			var existing = Sys.getEnv(pin.variable);
			if (existing != null && existing != "" && FileSystem.exists(existing)) {
				resolved.set(pin.variable, existing);
				done.release();
				continue;
			}
			Thread.create(() -> {
				try {
					var path = artifacts.resolve({main: pin.main, classPaths: [], defines: []});
					mutex.acquire();
					resolved.set(pin.variable, path);
					mutex.release();
				} catch (error:Dynamic) {
					mutex.acquire();
					errors.push('${pin.main}: $error');
					mutex.release();
				}
				done.release();
			});
		}
		for (_ in pins)
			done.wait();
		if (errors.length > 0) {
			console(errors.join("\n"));
			return false;
		}
		// Set before any suite starts: no thread reads or writes the environment after this.
		for (variable in resolved.keys())
			Sys.putEnv(variable, resolved.get(variable));
		Sys.putEnv("HAXEON_HASHLINK_DIR", build.HashLinkPath.directory(home));
		Sys.putEnv("HAXEON_NATIVE_READY", "1");
		// The suites that require Wasmtime run the one found here, wherever it was found.
		var wasmtime = wasmtimePath();
		if (wasmtime != null)
			Sys.putEnv("WASMTIME", wasmtime);
		var haxe = Sys.getEnv("HAXEON_HAXE");
		launcherActive = haxe == null || haxe == "";
		return true;
	}

	function startLane(members:Array<Suite>):{lock:Lock, results:Array<SuiteResult>} {
		var lane = {lock: new Lock(), results: []};
		console('${prefix()}lane ${members[0].lane}, in the background: ${members.map(suite -> suite.name).join(" ")}');
		Thread.create(() -> {
			for (suite in members)
				lane.results.push(runOne(suite, false));
			lane.lock.release();
		});
		return lane;
	}

	function runPool(members:Array<Suite>):Void {
		var limit = Std.int(Math.max(1, Math.min(options.jobs, POOL_LIMIT))),
			results:Array<Null<SuiteResult>> = [for (_ in members) null],
			next = 0,
			mutex = new Mutex(),
			done = new Lock(),
			workers = Std.int(Math.min(limit, members.length));
		console('${prefix()}pool ${members[0].pool}, $workers at a time: ${members.map(suite -> suite.name).join(" ")}');
		for (_ in 0...workers)
			Thread.create(() -> {
				while (true) {
					mutex.acquire();
					var index = next++;
					mutex.release();
					if (index >= members.length)
						break;
					results[index] = runOne(members[index], false);
				}
				done.release();
			});
		for (_ in 0...workers)
			done.wait();
		for (result in results)
			printLog(result);
	}

	/** Runs a suite to its end; `stream` copies its output to the console as it comes, else the caller prints the log later. */
	function runOne(suite:Suite, stream:Bool):SuiteResult {
		var log = Path.join([directory, suite.name + ".log"]),
			skip = skipReason(suite);
		if (skip != null) {
			File.saveContent(log, 'SKIP: ${suite.name}: $skip\n');
			if (stream)
				console('SKIP: ${suite.name}: $skip');
			record('${suite.name}: skipped ($skip)');
			return {
				suite: suite,
				status: null,
				seconds: 0,
				skipReason: skip,
				log: log
			};
		}
		if (options.gate && suite.lane == null && suite.pool == null)
			console('${prefix()}${suite.name}');
		ensureDirectory(suiteOutput(suite));
		var began = Sys.time(),
			status = runScript(script(suite), log, stream),
			seconds = Std.int(Sys.time() - began),
			timing = 'TIMING: ${suite.name}: ${seconds}s (exit $status)';
		appendLine(log, timing);
		if (stream)
			console(timing);
		if (status != 0)
			failed = true;
		var line = '${suite.name}: exit $status, $seconds s',
			driver = lastLine(log, "Test driver: ");
		if (driver != null)
			line += ', $driver';
		record(line);
		if (StringTools.startsWith(suite.name, "driver-"))
			record('${suite.name} coverage: ${coverage(log)}');
		return {
			suite: suite,
			status: status,
			seconds: seconds,
			skipReason: null,
			log: log
		};
	}

	/** A directory of the suite's own, for files no other suite may write: HAXEON_SUITE_OUT. */
	function suiteOutput(suite:Suite):String
		return Path.join([directory, suite.name + ".out"]);

	function script(suite:Suite):String {
		var lines = [
			'cd ${quote(home)} || exit 2',
			'export HAXEON_SUITE_OUT=${quote(suiteOutput(suite))}'
		];
		if (suite.freshNative)
			lines.push("unset HAXEON_NATIVE_READY");
		if (suite.cliLauncher && launcherActive)
			lines.push('export HAXEON_HAXE=${quote(Path.join([home, "scripts", "test-cli-launcher.sh"]))} HAXEON_REAL_HAXE=${quote(new ToolArtifacts(home).haxe())}');
		lines.push(StringTools.replace(suite.command, "{jobs}", Std.string(options.jobs)));
		return lines.join("\n");
	}

	/** Runs `command` with bash from the repository root, stdout and stderr together into `log` (and the console when streaming). */
	function runScript(command:String, log:String, stream:Bool):Int {
		launchMutex.acquire();
		var process = try new Process("bash", ["-c", 'exec 2>&1\n$command']) catch (error:Dynamic) {
			launchMutex.release();
			File.saveContent(log, 'Could not start bash: $error\n');
			return 127;
		};
		launchMutex.release();
		process.stdin.close();
		var output = File.write(log), buffer = Bytes.alloc(16384);
		try {
			while (true) {
				var count = process.stdout.readBytes(buffer, 0, buffer.length);
				if (count <= 0)
					break;
				output.writeBytes(buffer, 0, count);
				if (stream) {
					consoleMutex.acquire();
					Sys.stdout().writeBytes(buffer, 0, count);
					Sys.stdout().flush();
					consoleMutex.release();
				}
			}
		} catch (_:haxe.io.Eof) {}
		output.close();
		var status = process.exitCode();
		process.close();
		return status;
	}

	function skipReason(suite:Suite):Null<String> {
		for (variable in suite.unlessEnv)
			if (Sys.getEnv(variable) == "1")
				return '$variable=1';
		for (tool in suite.requires)
			if (tool == "wasmtime" && !wasmtimeAvailable())
				return "Wasmtime 47.0.0 is not installed; set WASMTIME to its executable";
		return null;
	}

	function wasmtimeAvailable():Bool {
		if (haveWasmtime == null)
			haveWasmtime = wasmtimePath() != null;
		return haveWasmtime;
	}

	/** Wasmtime: WASMTIME, else the pinned copy under .tools, else the one on PATH; null when there is none. */
	function wasmtimePath():Null<String> {
		var configured = Sys.getEnv("WASMTIME");
		if (configured != null && configured != "")
			return configured;
		var pinned = Path.join([home, ".tools", "wasmtime-47.0.0", "wasmtime"]);
		if (FileSystem.exists(pinned))
			return pinned;
		return onPath("wasmtime") ? "wasmtime" : null;
	}

	function printLog(result:SuiteResult):Void {
		if (options.gate)
			return;
		console(StringTools.rtrim(File.getContent(result.log)));
	}

	function finish():Int {
		record('elapsed: ${Std.int(Sys.time() - started)} s load at end: ${load()}');
		var status = failed ? 1 : 0;
		record('exit: $status');
		summary.close();
		var text = File.getContent(Path.join([directory, "summary.txt"]));
		console(options.gate ? StringTools.rtrim(text) : 'summary: ${Path.join([directory, "summary.txt"])}');
		return status;
	}

	/** Counts the program cases a driver log shows passing, by build kind. */
	static function coverage(log:String):String {
		var live = 0, plain = 0, warm = 0, pruned = 0, prunedWarm = 0;
		for (line in File.getContent(log).split("\n")) {
			if (!StringTools.startsWith(line, "PASS: ") || line.indexOf(" source compiled and executed") < 0)
				continue;
			if (line.indexOf("(warm edit rebuilds, no early prune) source compiled") >= 0)
				prunedWarm++;
			else if (line.indexOf("(plain build, no early prune) source compiled") >= 0)
				pruned++;
			else if (line.indexOf("(warm edit rebuilds) source compiled") >= 0)
				warm++;
			else if (line.indexOf("(plain build) source compiled") >= 0)
				plain++;
			else
				live++;
		}
		return 'programs: $live live, $plain plain, $pruned plain+no-early-prune, warm-edit: ${warm > 0 ? 'yes ($warm)' : "no"}, '
			+ 'warm-edit+no-early-prune: ${prunedWarm > 0 ? 'yes ($prunedWarm)' : "no"}';
	}

	function record(line:String):Void {
		summaryMutex.acquire();
		summary.writeString(line + "\n");
		summary.flush();
		summaryMutex.release();
	}

	function console(text:String):Void {
		consoleMutex.acquire();
		Sys.println(text);
		consoleMutex.release();
	}

	function prefix():String
		return options.gate ? "gate: " : "test: ";

	static function lastLine(path:String, start:String):Null<String> {
		var found:Null<String> = null;
		for (line in File.getContent(path).split("\n"))
			if (StringTools.startsWith(line, start))
				found = StringTools.trim(line);
		return found;
	}

	static function appendLine(path:String, line:String):Void {
		var output = File.append(path);
		output.writeString(line + "\n");
		output.close();
	}

	/** The 1-minute load average. /proc files report size 0, so they are read as a stream, not with File.getContent. */
	static function load():String {
		if (!FileSystem.exists("/proc/loadavg"))
			return "n/a";
		var input = File.read("/proc/loadavg");
		var text = try input.readAll().toString() catch (_:Dynamic) "";
		input.close();
		var value = text.split(" ")[0];
		return value == "" ? "n/a" : value;
	}

	static function cores():String
		return try StringTools.trim(capture("getconf", ["_NPROCESSORS_ONLN"])) catch (_:Dynamic) "n/a";

	static function git(home:String, arguments:Array<String>):String
		return try StringTools.rtrim(capture("git", ["-C", home].concat(arguments))) catch (_:Dynamic) "";

	static function capture(command:String, arguments:Array<String>):String {
		var process = new Process(command, arguments);
		var text = process.stdout.readAll().toString();
		process.exitCode();
		process.close();
		return text;
	}

	static function onPath(name:String):Bool {
		var path = Sys.getEnv("PATH");
		if (path == null)
			return false;
		for (entry in path.split(Sys.systemName() == "Windows" ? ";" : ":"))
			if (entry != "" && FileSystem.exists(Path.join([entry, name])))
				return true;
		return false;
	}

	static function quote(text:String):String
		return "'" + StringTools.replace(text, "'", "'\\''") + "'";

	/** Keeps the newest runs of `dev test` (gate runs are reports and are kept). */
	static function pruneRuns(root:String):Void {
		if (!FileSystem.exists(root))
			return;
		var runs = FileSystem.readDirectory(root).filter(entry -> FileSystem.isDirectory(Path.join([root, entry])));
		runs.sort((a, b) -> a < b ? 1 : a > b ? -1 : 0);
		for (index in KEPT_RUNS - 1...runs.length)
			removeTree(Path.join([root, runs[index]]));
	}

	static function removeTree(path:String):Void {
		if (FileSystem.isDirectory(path)) {
			for (entry in FileSystem.readDirectory(path))
				removeTree(Path.join([path, entry]));
			FileSystem.deleteDirectory(path);
		} else
			FileSystem.deleteFile(path);
	}

	static function ensureDirectory(path:String):Void {
		if (FileSystem.exists(path))
			return;
		ensureDirectory(Path.directory(path));
		FileSystem.createDirectory(path);
	}
}
