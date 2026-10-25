package tools;

import haxe.io.Path;
import haxe.Json;
import sys.FileSystem;
import sys.io.File;
import sys.io.Process;

/** How a profiled run records: when recording starts, when it stops, and what part of the capture is exported. */
typedef ProfileControls = {
	/** "launch" records from the program's start; "manual" opens the session paused until the program starts it. */
	final start:String;

	/** Seconds of recording after which the session stops; 0 for no limit. */
	final durationSeconds:Int;

	/** Capture size in MiB at which the session stops; 0 for no limit. */
	final maxSizeMiB:Int;

	/** The exported part of the capture, `START:END` in seconds since the recorder connected (either side optional). */
	final window:Null<String>;

	/** Calls shorter than this many microseconds are dropped (0 keeps every call); null takes the project's `instrument.minCallMicros`. */
	final minCallMicros:Null<Float>;
}

/**
	One profiled run of a program: the program waits on a diagnostics port, `hlprof-live` records its samples, spans and
	counters as an HLPC capture, and the finished capture is also exported as a Perfetto trace next to it.
**/
class ProfileCapture {
	public final capture:String;
	public final port:Int;

	final profiler:String;
	final processName:String;
	final sources:Array<String>;
	final directory:String;
	final name:String;
	final revisions:Array<String> = [];
	var recorder:Null<Process>;

	public function new(profiler:String, capture:String, processName:String, sources:Array<String>) {
		this.profiler = profiler;
		this.capture = capture;
		this.processName = processName;
		this.sources = sources;
		directory = Path.directory(capture);
		name = Path.withoutExtension(Path.withoutDirectory(capture));
		port = allocatePort();
		ensureDirectory(directory);
		// capture.json describes one capture, so a directory holds one capture; recording the same path again replaces it.
		var manifest = Path.join([directory, "capture.json"]);
		if (FileSystem.exists(manifest)) {
			var artifacts:Dynamic = Reflect.field(Json.parse(File.getContent(manifest)), "artifacts");
			if (artifacts == null || Reflect.field(artifacts, "profile") != Path.withoutDirectory(capture))
				throw 'Capture directory $directory already holds another capture; choose an empty directory';
		}
	}

	/** A capture stops at this size unless the run asks for another limit: larger traces are slow to load in Perfetto. */
	public static inline final DEFAULT_MAX_SIZE_MIB = 4096;

	/** The recording controls of this run's captures, set from the command line. */
	public static var controls:ProfileControls = {
		start: "launch",
		durationSeconds: 0,
		maxSizeMiB: DEFAULT_MAX_SIZE_MIB,
		window: null,
		minCallMicros: null
	};

	/** The run's minimum call duration in microseconds, resolved from the controls and the project. */
	public static var minCallMicros:Float = project.PackageManifest.InstrumentManifest.DEFAULT_MIN_CALL_MICROS;

	/** HL_PROF_BOUNDARY for an instrumented run: which boundary hooks the runtime installs (see prof_boundary.c). */
	public static function boundaryConfiguration(instrument:project.PackageManifest.InstrumentManifest):String {
		var parts = ['imports=${instrument.boundaryImports}', 'dxgi=${instrument.dxgi ? 1 : 0}', 'd3d11=${instrument.d3d11 ? 1 : 0}',
			'vulkan=${instrument.vulkan ? 1 : 0}'];
		if (instrument.boundaryExtra.length > 0)
			parts.push('extra=${instrument.boundaryExtra.join(",")}');
		return parts.join(";");
	}

	/** Instrumentation: every call of the instrumented build, Haxe and native, as a slice. */
	public static function defaultSources():Array<String>
		return ["instrument"];

	/** Parses a comma list of profiling sources: instrument, sampling, alloc. */
	public static function parseSources(list:String):Array<String> {
		var sources = [];
		for (source in list.split(",")) {
			source = StringTools.trim(source);
			if (source != "instrument" && source != "sampling" && source != "alloc")
				throw 'Unknown profiling source "$source" (expected instrument, sampling or alloc)';
			if (sources.indexOf(source) < 0)
				sources.push(source);
		}
		return sources;
	}

	/** Parses `--profile-start`: "launch" or "manual". */
	public static function parseStart(value:String):String {
		if (value != "launch" && value != "manual")
			throw 'Option "--profile-start" must be "launch" or "manual"';
		return value;
	}

	/** Parses `--profile-min-call`: microseconds, at least 0. */
	public static function parseMinCall(value:String):Float {
		var parsed = number(value);
		if (parsed == null || parsed > 4000000)
			throw 'Option "--profile-min-call" takes microseconds from 0 to 4000000, not "$value"';
		return parsed;
	}

	/** Parses `--profile-window`: `START:END` in seconds, either side optional. */
	public static function parseWindow(value:String):String {
		windowArguments(value);
		return value;
	}

	/** A plain non-negative decimal number, all of value (so "1ms" is refused, not read as 1); null otherwise. */
	static function number(value:String):Null<Float> {
		var text = StringTools.trim(value);
		return ~/^([0-9]+(\.[0-9]*)?|\.[0-9]+)$/.match(text) ? Std.parseFloat(text) : null;
	}

	/** The exporter's arguments for a window, in milliseconds. */
	static function windowArguments(window:Null<String>):Array<String> {
		if (window == null)
			return [];
		var parts = window.split(":");
		if (parts.length != 2)
			throw 'Option "--profile-window" takes START:END in seconds';
		var arguments = [], bounds:Array<Null<Float>> = [null, null];
		for (index in 0...2) {
			if (StringTools.trim(parts[index]) == "")
				continue;
			var seconds = number(parts[index]);
			if (seconds == null)
				throw 'Option "--profile-window" takes START:END in seconds, not "$window"';
			bounds[index] = seconds;
			arguments.push(index == 0 ? "--start-ms" : "--end-ms");
			arguments.push(Std.string(Math.round(seconds * 1000)));
		}
		if (bounds[0] != null && bounds[1] != null && bounds[0] >= bounds[1])
			throw 'Option "--profile-window" needs START before END, not "$window"';
		return arguments;
	}

	/** A new capture directory under root, named by its start time. */
	public static function nextCapture(root:String):String {
		var stamp = DateTools.format(Date.now(), "%Y%m%d-%H%M%S"), directory = Path.join([root, 'profile-$stamp']), suffix = 2;
		while (FileSystem.exists(directory))
			directory = Path.join([root, 'profile-$stamp-${suffix++}']);
		return Path.join([directory, "profile.hlpc"]);
	}

	/** HashLink arguments that hold the program before its entry point until the recorder attaches. */
	public function runtimeArguments():Array<String>
		return ["--diagnostics", Std.string(port), "--diagnostics-wait"];

	public function recorderArguments():Array<String> {
		var arguments = ["--connect-timeout", "15", "--sources", sources.join(","), "--rate", "1000"];
		if (sources.indexOf("alloc") >= 0)
			arguments = arguments.concat(["--alloc-interval", "65536"]);
		if (controls.start == "manual")
			arguments.push("--paused");
		if (controls.durationSeconds > 0)
			arguments = arguments.concat(["--duration", Std.string(controls.durationSeconds)]);
		if (controls.maxSizeMiB > 0)
			arguments = arguments.concat(["--max-size", Std.string(controls.maxSizeMiB)]);
		if (sources.indexOf("instrument") >= 0 && minCallMicros > 0)
			arguments = arguments.concat(["--min-call-us", Std.string(minCallMicros)]);
		return arguments.concat(["--interval", "2000", "--output", capture, Std.string(port)]);
	}

	/** Copies the bytecode the program is launched with into the capture. Call it before the launch, while the file is that build. */
	public function keepBytecode(bytecode:String):Void
		File.copy(bytecode, Path.join([directory, '$name.hl']));

	/** Copies a later build that a live run patched or reloaded into, so each revision's code is kept with the capture. */
	public function keepRevision(bytecode:String):Void {
		var revision = '$name.r${revisions.length + 2}.hl';
		File.copy(bytecode, Path.join([directory, revision]));
		revisions.push(revision);
	}

	/** Starts the recorder with its console output in recorder.log, for callers that do not show it. */
	public function startRecorder():Void {
		var log = recorderLog();
		var arguments = [profiler].concat(recorderArguments());
		recorder = Sys.systemName() == "Windows" ? new Process(arguments.map(windowsQuote)
			.join(" ") + " > " + windowsQuote(log) + " 2>&1") : new Process("/bin/sh", [
				"-c",
				"exec " + arguments.map(shellQuote).join(" ") + " > " + shellQuote(log) + " 2>&1"
			]);
	}

	public function recorderLog():String
		return Path.join([directory, "recorder.log"]);

	/** The exit status of a recorder started by startRecorder that has already failed, or null while it runs or after it succeeded. */
	public function recorderFailure():Null<Int> {
		var status = recorder == null ? null : recorder.exitCode(false);
		return status == null || status == 0 ? null : status;
	}

	/**
		Waits for the recorder started by startRecorder to finalize the capture after the program exits, then exports it.
		Returns the Perfetto trace, or null when the capture could not be finalized or exported.
	**/
	public function finishRecorder():Null<String> {
		var recorder = this.recorder;
		if (recorder == null)
			return null;
		this.recorder = null;
		var deadline = Sys.time() + 15.0, status:Null<Int> = null;
		while ((status = recorder.exitCode(false)) == null && Sys.time() < deadline)
			Sys.sleep(0.05);
		if (status == null) {
			// On Windows the recorder runs under cmd.exe, so the whole tree must be stopped.
			if (Sys.systemName() == "Windows") {
				var taskkill = new Process("taskkill", ["/T", "/F", "/PID", Std.string(recorder.getPid())]);
				taskkill.exitCode();
				taskkill.close();
			} else
				recorder.kill();
			status = recorder.exitCode();
		}
		recorder.close();
		if (status != 0) {
			Sys.stderr().writeString('haxeon: profiler capture did not finalize cleanly (status $status); see ${recorderLog()}\n');
			return null;
		}
		return complete();
	}

	/** Exports the finished capture for Perfetto and writes the capture manifest. Returns the trace, or null on failure. */
	public function complete():Null<String> {
		var trace = Path.join([directory, '$name.pftrace']);
		var export = new Process(profiler, ["export", "--format", "pftrace", "--process-name", processName].concat(windowArguments(controls.window))
			.concat(["--output", trace, capture]));
		// The export prints the dropped short calls, which the report after the run shows too; reading it keeps the pipe
		// from filling.
		export.stdout.readAll();
		var errors = export.stderr.readAll().toString(),
			status = export.exitCode();
		export.close();
		var artifacts:Dynamic = {bytecode: '$name.hl', profile: Path.withoutDirectory(capture)};
		if (revisions.length > 0)
			artifacts.liveRevisions = revisions;
		if (status == 0)
			artifacts.perfetto = Path.withoutDirectory(trace);
		else
			Sys.stderr().writeString('haxeon: Perfetto export failed (status $status): $errors\n');
		File.saveContent(Path.join([directory, "capture.json"]), Json.stringify({
			schemaVersion: 1,
			kind: "haxeon.capture",
			artifacts: artifacts
		}, null, "  ") + "\n");
		return status == 0 ? trace : null;
	}

	static function allocatePort():Int {
		for (_ in 0...20) {
			var port = 20000 + Std.random(40000),
				socket = new sys.net.Socket();
			try {
				socket.bind(new sys.net.Host("127.0.0.1"), port);
				socket.close();
				return port;
			} catch (_:Dynamic) {
				socket.close();
			}
		}
		throw "Could not find a free diagnostics port for profiling";
	}

	static function ensureDirectory(path:String):Void
		if (path != "" && !FileSystem.exists(path))
			FileSystem.createDirectory(path);

	static function shellQuote(value:String):String
		return "'" + value.split("'").join("'\\''") + "'";

	static function windowsQuote(value:String):String
		return '"' + value.split('"').join('\\"') + '"';
}
