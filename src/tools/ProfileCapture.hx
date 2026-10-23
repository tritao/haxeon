package tools;

import haxe.io.Path;
import haxe.Json;
import sys.FileSystem;
import sys.io.File;
import sys.io.Process;

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

	/** Instrumentation: every call of the instrumented build, Haxe and native, as a slice. */
	/** HL_PROF_BOUNDARY for an instrumented run: which boundary hooks the runtime installs (see prof_boundary.c). */
	public static function boundaryConfiguration(instrument:project.PackageManifest.InstrumentManifest):String {
		var parts = ['imports=${instrument.boundaryImports}', 'dxgi=${instrument.dxgi ? 1 : 0}', 'd3d11=${instrument.d3d11 ? 1 : 0}',
			'vulkan=${instrument.vulkan ? 1 : 0}'];
		if (instrument.boundaryExtra.length > 0)
			parts.push('extra=${instrument.boundaryExtra.join(",")}');
		return parts.join(";");
	}

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
		var export = new Process(profiler, [
			"export",
			"--format",
			"pftrace",
			"--process-name",
			processName,
			"--output",
			trace,
			capture
		]);
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
