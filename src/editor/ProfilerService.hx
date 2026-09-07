package editor;

import haxe.Int64;
import profiler.HldiClient;
import profiler.ProfilerSession;
import profiler.ProfilerSession.ProfileAggregate;
import profiler.ProfilerSession.ProfileLeaf;
import profiler.ProfilerSession.ProfileStack;
import profiler.ProfilerSession.ProfilerSnapshot;
import profiler.ProfilerSession.ProfilerSessionState;
import sys.thread.Lock;
import sys.thread.Mutex;
import sys.thread.Thread;

/** Thread-safe editor-facing owner for one remote HLDI profiling session. */
class ProfilerService {
	final mutex = new Mutex();
	final wake = new Lock();
	final stopped = new Lock();
	var session:Null<ProfilerSession>;
	var emitter:Null<Dynamic->Void>;
	var workerStarted = false;
	var stopping = false;
	var pollIntervalSeconds = 0.1;
	var notificationSequence = 0;
	var maxEntries = 100;
	var emittedMetadataChanges = 0;
	final viewModel = new ProfilerViewModel();

	public function new() {}

	public function setEmitter(emitter:Dynamic->Void):Void
		this.emitter = emitter;

	public function execute(command:String, arguments:Array<Dynamic>):Dynamic {
		var options:Dynamic = arguments.length == 0 || arguments[0] == null ? {} : arguments[0];
		mutex.acquire();
		try {
			var result = switch command {
				case "haxeon.profiler.connect": connect(options);
				case "haxeon.profiler.start": start(options);
				case "haxeon.profiler.pause": pause();
				case "haxeon.profiler.poll": poll();
				case "haxeon.profiler.reset": reset();
				case "haxeon.profiler.snapshot": currentSnapshot();
				case "haxeon.profiler.captureStart": captureStart(options);
				case "haxeon.profiler.captureStop": captureStop();
				case "haxeon.profiler.disconnect": disconnect();
				default: throw 'Unknown Haxeon profiler command "$command"';
			};
			mutex.release();
			return result;
		} catch (error:Dynamic) {
			mutex.release();
			throw error;
		}
	}

	public function close():Void {
		mutex.acquire();
		if (stopping) {
			mutex.release();
			return;
		}
		stopping = true;
		if (session != null) {
			session.close();
			session = null;
		}
		var wait = workerStarted;
		mutex.release();
		wake.release();
		if (wait)
			stopped.wait();
	}

	function connect(options:Dynamic):Dynamic {
		if (session != null)
			session.close();
		session = null;
		var host = stringOption(options, "host", "127.0.0.1"), port = requiredInt(options, "port"), timeout = floatOption(options, "timeoutSeconds", 5.0),
			requestedMaxEntries = intOption(options, "maxEntries", 100), token = optionalString(options, "token");
		if (requestedMaxEntries < 1)
			throw "Profiler maxEntries must be positive";
		session = new ProfilerSession(new HldiClient(host, port, timeout, token));
		viewModel.reset();
		emittedMetadataChanges = 0;
		if (Reflect.hasField(options, "leafCapacity"))
			session.leafCapacity = requiredInt(options, "leafCapacity");
		if (Reflect.hasField(options, "eventCapacity"))
			session.eventCapacity = requiredInt(options, "eventCapacity");
		maxEntries = requestedMaxEntries;
		ensureWorker();
		return currentSnapshot();
	}

	function start(options:Dynamic):Dynamic {
		var current = requireSession(), rate = intOption(options, "sampleRate", 1000), interval = intOption(options, "pollIntervalMs", 100);
		if (interval < 10)
			throw "Profiler polling interval must be at least 10ms";
		pollIntervalSeconds = interval / 1000.0;
		current.start(rate);
		wake.release();
		return snapshot(current.snapshot());
	}

	function pause():Dynamic {
		var current = requireSession();
		current.pause();
		return snapshot(current.snapshot());
	}

	function poll():Dynamic {
		var current = requireSession();
		current.poll();
		return snapshot(current.snapshot());
	}

	function reset():Dynamic {
		var current = requireSession();
		current.reset();
		viewModel.reset();
		emittedMetadataChanges = 0;
		return snapshot(current.snapshot());
	}

	function disconnect():Dynamic {
		if (session != null)
			session.close();
		session = null;
		return {state: "disconnected"};
	}

	function captureStart(options:Dynamic):Dynamic {
		var current = requireSession(), path = stringOption(options, "path", "");
		if (path.length == 0) throw "Profiler capture path must not be empty";
		current.startCapture(path);
		return snapshot(current.snapshot());
	}

	function captureStop():Dynamic {
		var current = requireSession();
		current.stopCapture();
		return snapshot(current.snapshot());
	}

	function currentSnapshot():Dynamic
		return session == null ? {state: "disconnected"} : snapshot(session.snapshot());

	function run():Void {
		while (true) {
			wake.wait(pollIntervalSeconds);
			var message:Dynamic = null, changes:Array<Dynamic> = [], output = emitter;
			mutex.acquire();
			if (stopping) {
				mutex.release();
				break;
			}
			if (session != null && session.state == Running)
				try {
					session.poll();
					message = snapshot(session.snapshot());
					while (emittedMetadataChanges < session.metadataChanges.length) {
						var change = session.metadataChanges[emittedMetadataChanges++];
						changes.push({timestamp: change.timestamp, moduleId: change.moduleId, oldRevision: change.oldRevision, newRevision: change.newRevision});
					}
				} catch (error:Dynamic) {
					message = snapshot(session.snapshot());
					Reflect.setField(message, "error", Std.string(error));
				}
			mutex.release();
			if (message != null && output != null) {
				output({method: "haxeon/profilerSnapshot", params: message});
				for (change in changes)
					output({method: "haxeon/profilerMetadataChanged", params: change});
			}
		}
		stopped.release();
	}

	function ensureWorker():Void {
		if (workerStarted)
			return;
		workerStarted = true;
		Thread.create(run);
	}

	function requireSession():ProfilerSession {
		if (session == null)
			throw "Profiler is not connected";
		return session;
	}

	function snapshot(value:ProfilerSnapshot):Dynamic {
		var result:Dynamic = {
			sequence: ++notificationSequence,
			state: Std.string(value.state),
			samples: value.samples,
			unresolvedFrames: value.unresolvedFrames,
			dropped: Int64.toStr(value.dropped),
			pendingBytes: value.pendingBytes,
			bufferCapacity: Int64.toStr(value.bufferCapacity),
			bufferUsed: Int64.toStr(value.bufferUsed),
			bufferUtilization: value.bufferUtilization,
			requestedSampleRate: value.requestedSampleRate,
			effectiveSampleRate: value.effectiveSampleRate,
			metadataRefreshMs: value.metadataRefreshMs,
			sampleRecords: Int64.toStr(value.sampleRecords),
			generatedBytes: Int64.toStr(value.generatedBytes),
			overheadMicrosPerSample: value.overheadMicrosPerSample,
			gcSamples: value.gcSamples,
			threads: [for (threadId => name in value.threads) {id: threadId, name: name}],
			metadataSchema: value.metadataSchema,
			metadataRevisions: [for (moduleId => revision in value.metadataRevisions) {moduleId: moduleId, revision: revision}],
			metadataChanges: [for (change in value.metadataChanges) {
				timestamp: change.timestamp,
				moduleId: change.moduleId,
				oldRevision: change.oldRevision,
				newRevision: change.newRevision
			}],
			functions: [for (aggregate in value.functions.slice(0, maxEntries)) aggregateValue(aggregate)],
			lines: [for (aggregate in value.lines.slice(0, maxEntries)) aggregateValue(aggregate)],
			stacks: [for (stack in value.stacks.slice(0, maxEntries)) stackValue(stack)],
			leaves: [for (leaf in value.leaves) leafValue(leaf)],
			events: [for (event in value.events) {
				timestamp: event.timestamp,
				threadId: event.threadId,
				eventId: event.eventId,
				payloadHex: event.payload.toHex()
			}],
			lastError: value.lastError
		};
		Reflect.setField(result, "captureActive", session != null && session.captureActive());
		var view = viewModel.update(result);
		Reflect.setField(result, "view", view.state);
		Reflect.setField(result, "viewDelta", view.delta);
		return result;
	}

	static function aggregateValue(value:ProfileAggregate):Dynamic
		return {
			key: value.key,
			stableKey: value.stableKey,
			name: value.name,
			file: value.file,
			line: value.line,
			selfSamples: value.selfSamples,
			totalSamples: value.totalSamples
		};

	static function stackValue(value:ProfileStack):Dynamic
		return {
			key: value.key,
			frames: value.frames,
			frameDetails: [for (frame in value.frameDetails) {
				key: frame.key, stableKey: frame.stableKey, name: frame.name, revision: frame.revision, file: frame.file, line: frame.line
			}],
			threadSamples: [for (threadId => samples in value.threadSamples) {threadId: threadId, samples: samples}],
			samples: value.samples
		};

	static function leafValue(value:ProfileLeaf):Dynamic
		return {
			timestamp: value.timestamp,
			threadId: value.threadId,
			pc: Int64.toStr(value.address),
			offset: value.offset,
			functionName: value.functionName,
			opcodeIndex: value.opcodeIndex,
			opcode: value.opcode,
			file: value.file,
			line: value.line
		};

	static function requiredInt(options:Dynamic, name:String):Int {
		var value:Dynamic = Reflect.field(options, name);
		if (!Std.isOfType(value, Int))
			throw 'Profiler option "$name" must be an integer';
		return cast value;
	}

	static function intOption(options:Dynamic, name:String, fallback:Int):Int
		return Reflect.hasField(options, name) ? requiredInt(options, name) : fallback;

	static function floatOption(options:Dynamic, name:String, fallback:Float):Float {
		if (!Reflect.hasField(options, name))
			return fallback;
		var value:Dynamic = Reflect.field(options, name);
		if (!Std.isOfType(value, Float) && !Std.isOfType(value, Int))
			throw 'Profiler option "$name" must be numeric';
		return cast value;
	}

	static function stringOption(options:Dynamic, name:String, fallback:String):String {
		if (!Reflect.hasField(options, name))
			return fallback;
		var value:Dynamic = Reflect.field(options, name);
		if (!Std.isOfType(value, String))
			throw 'Profiler option "$name" must be a string';
		return cast value;
	}

	static function optionalString(options:Dynamic, name:String):Null<String> {
		if (!Reflect.hasField(options, name) || Reflect.field(options, name) == null)
			return null;
		var value:Dynamic = Reflect.field(options, name);
		if (!Std.isOfType(value, String))
			throw 'Profiler option "$name" must be a string';
		return cast value;
	}
}
