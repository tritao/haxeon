package haxeon.ui.host;

import haxe.Json;
import haxeon.platform.FrameRecorder;
import haxeon.platform.Surface;
import haxeon.platform.SurfaceFrameTiming;
import haxeon.platform.event.EventPump;
import haxeon.platform.event.EventSubscription;
import haxeon.platform.event.PlatformEvent;
import haxeon.ui.Renderer;
import hl.Gc;
import nativekit.ffi.NativeKit;
import nativekit.ffi.NativeKitTypes.NativeWindowKind;
import nativekit.ffi.NativeKitTypes.Result;
import nativekit.ffi.NativeKitTypes.WindowHandle;
import sys.FileSystem;
import sys.io.File;

/** Records desktop UI frame timing and writes capture artifacts. */
class DesktopFrameRecorder {

	final options:DesktopUiHostOptions;
	public final enabled:Bool;
	final eventHistory:Array<String> = [];
	final frameHistory:Array<Dynamic> = [];
	final timingRecorder = new FrameRecorder();
	var allocationCensusStarted = false;
	var startedAt = -1.0;
	var readyFrames = 0;
	var callbackSeconds = 0.0;
	var requestReason = "none";
	var requestSerial = 0;
	var requestedAt = -1.0;
	var inputRequestedAt = -1.0;
	var lastInputDeliveredAt = -1.0;
	var inputRequestCount = 0;
	var pointerRequestedAt = -1.0;
	var latestPointerAt = -1.0;
	var pointerMoveCount = 0;
	var inputDispatchSeconds = 0.0;
	var measuring = false;
	var phaseStarted = 0.0;
	var callbackBeforePhase = 0.0;
	var framesBeforePhase = 0;
	var backgroundStarted = 0.0;
	final loopTiming = {
		loops: 0,
		waits: 0,
		pollSeconds: 0.0,
		backgroundSeconds: 0.0,
		waitSeconds: 0.0,
		pollFrameSeconds: 0.0,
		waitFrameSeconds: 0.0,
		pollFrames: 0,
		waitFrames: 0
	};
	final eventCounts:Map<String, Int> = new Map();
	final frameRequestCounts:Map<String, Int> = new Map();

	var presentation:Null<SurfaceFrameTiming>;
	var frameStartedAt = 0.0;
	var gcCountBefore = 0.0;
	var gcMicrosBefore = 0.0;
	var collectionStartedAt = 0.0;
	var collectionSeconds = 0.0;
	var frame:{
		scriptedFrameCount:Int,
		scriptedFrameAt:Float,
		scriptedFrameDeliveredAt:Float,
		scriptedFrameDispatch:Float
	};
	var pointerFirstAt = -1.0;
	var pointerLatestAt = -1.0;
	var pointerCount = 0;
	var textInputRequestedAt = -1.0;
	var textInputCount = 0;
	var textInputDispatchSeconds = 0.0;
	var frameRequestedAt = -1.0;
	var frameRequestReason = "none";
	var frameRequestSerial = 0;

	public function new(options:DesktopUiHostOptions) {
		this.options = options;
		enabled = options.captureDirectory != null;
	}

	public function attach(pump:EventPump, window:WindowHandle):Null<EventSubscription> {
		if (!enabled) return null;
		return pump.listen(function(value) {
			switch value {
				case PointerMove(source, _, _) if (source.rawValue() == window.rawValue()):
					latestPointerAt = Sys.time();
					if (pointerRequestedAt < 0) pointerRequestedAt = latestPointerAt;
					pointerMoveCount++;
				case TextInput(source, _) if (source.rawValue() == window.rawValue()):
					lastInputDeliveredAt = Sys.time();
					if (inputRequestedAt < 0.0) inputRequestedAt = lastInputDeliveredAt;
					inputRequestCount++;
				case _:
			}
		});
	}

	public function event(value:PlatformEvent, name:String):Void {
		if (!enabled) return;
		if (name == "TextInput" && lastInputDeliveredAt >= 0.0)
			inputDispatchSeconds += Sys.time() - lastInputDeliveredAt;
		increment(eventCounts, name);
		if (options.eventHistoryLimit > 0) {
			eventHistory.push(Std.string(value));
			while (eventHistory.length > options.eventHistoryLimit) eventHistory.shift();
		}
	}

	public function request(reason:String):Void {
		if (!enabled) return;
		requestedAt = Sys.time();
		requestReason = reason;
		requestSerial++;
		increment(frameRequestCounts, reason);
	}

	public function callbackTime():Float return enabled ? Sys.monotonicTime() : 0.0;

	public function begin(surface:Surface, callbackAt:Float, scriptedFrameCount:Int, scriptedFrameAt:Float,
			scriptedFrameDeliveredAt:Float, scriptedFrameDispatch:Float):Void {
		if (!enabled) return;
		presentation = timingRecorder.begin(surface, callbackAt);
		frameStartedAt = Sys.time();
		gcCountBefore = Gc.collections();
		gcMicrosBefore = Gc.markMicros();
		frame = {
			scriptedFrameCount: scriptedFrameCount,
			scriptedFrameAt: scriptedFrameAt,
			scriptedFrameDeliveredAt: scriptedFrameDeliveredAt,
			scriptedFrameDispatch: scriptedFrameDispatch
		};
		pointerFirstAt = pointerRequestedAt;
		pointerLatestAt = latestPointerAt;
		pointerCount = pointerMoveCount;
		pointerRequestedAt = -1.0;
		latestPointerAt = -1.0;
		pointerMoveCount = 0;
		textInputRequestedAt = inputRequestedAt;
		textInputCount = inputRequestCount;
		textInputDispatchSeconds = inputDispatchSeconds;
		inputRequestedAt = -1.0;
		inputRequestCount = 0;
		inputDispatchSeconds = 0.0;
		frameRequestedAt = requestedAt;
		frameRequestReason = requestReason;
		frameRequestSerial = requestSerial;
	}

	public function submitted(rendered:Bool):Void {
		if (!enabled) return;
		if (rendered && presentation != null) presentation.markSubmitted();
		collectionStartedAt = Sys.time();
	}

	public function endRender():Void {
		if (!enabled) return;
		collectionSeconds = Sys.time() - collectionStartedAt;
		callbackSeconds += Sys.time() - frameStartedAt;
	}

	public function finishedAt():Float return enabled ? Sys.time() : 0.0;

	public function ready():Bool {
		var check = options.captureReady;
		if (check != null && !check()) return false;
		readyFrames++;
		if (enabled) {
			if (options.captureSeconds > 0.0 && startedAt < 0.0) startedAt = frameStartedAt;
		}
		return true;
	}

	public function finishFrame(liveRuntime:UiHostRuntime, repaintOnly:Bool, frameFinishedAt:Float):Void {
		if (!enabled) return;
		if (!allocationCensusStarted && startedAt >= 0.0 && frameStartedAt - startedAt >= 4.0
			&& Sys.getEnv("MATERIA_CAPTURE_ALLOCATIONS") == "1") {
			allocationCensusStarted = true;
			Gc.censusReset();
			Gc.censusStart(65536);
		}
		var metrics = liveRuntime.app() == null
			? null : liveRuntime.app().context().frameMetrics;
		var displayedAt:Null<Float> = null;
		var record = {
			frame: liveRuntime.rendered,
			pointerMoveCount: pointerCount,
			pointerToPaintSeconds: pointerFirstAt < 0
				? null : frameFinishedAt - pointerFirstAt,
			latestPointerToPaintSeconds: pointerLatestAt < 0
				? null : frameFinishedAt - pointerLatestAt,
			hoverPaintUpdatedNodes: metrics == null
				? 0 : metrics.hoverPaintUpdatedNodes,
			reusedSubmission: metrics == null ? false : metrics.reusedSubmission,
			repaintOnly: repaintOnly,
			allocatedBytes: liveRuntime.lastFrameAllocatedBytes,
			prepareSeconds: liveRuntime.lastPrepareSeconds,
			applicationSubmitSeconds: liveRuntime.lastApplicationSubmitSeconds,
			contextRenderSeconds: liveRuntime.lastContextRenderSeconds,
			prepareAllocatedBytes: liveRuntime.lastPrepareAllocatedBytes,
			submitAllocatedBytes: liveRuntime.lastSubmitAllocatedBytes,
			startedAtSeconds: frameStartedAt,
			presentationFrameId: presentation == null || presentation.frameId == null
				? null : Std.string(presentation.frameId),
			callbackMonotonicSeconds: presentation == null ? null : presentation.callbackSeconds,
			submittedMonotonicSeconds: presentation == null ? null : presentation.submittedSeconds,
			presentedMonotonicSeconds: displayedAt,
			requestReason: frameRequestReason,
			requestSerial: frameRequestSerial,
			scriptedInputCount: frame.scriptedFrameCount,
			scriptedInputRequestAgeSeconds: frame.scriptedFrameAt < 0
				? null : frameStartedAt - frame.scriptedFrameAt,
			scriptedInputDeliveryAgeSeconds: frame.scriptedFrameDeliveredAt < 0
				? null : frameStartedAt - frame.scriptedFrameDeliveredAt,
			scriptedInputDispatchSeconds: frame.scriptedFrameDispatch,
			textInputCount: textInputCount,
			textInputRequestAgeSeconds: textInputRequestedAt < 0.0
				? null : frameStartedAt - textInputRequestedAt,
			textInputDispatchSeconds: textInputDispatchSeconds,
			requestAgeSeconds: frameRequestedAt < 0.0 ? null : frameStartedAt - frameRequestedAt,
			frameSeconds: frameFinishedAt - frameStartedAt,
			paintSeconds: liveRuntime.lastPaintSeconds,
			bookkeepingSeconds: 0.0,
			gcSeconds: 0.0,
			gcCollectionsTotal: 0.0,
			gcSecondsTotal: 0.0,
			frameGcSeconds: collectionSeconds,
			gcCollections: 0.0,
			gcLastPauseSeconds: Gc.lastPauseMicros() / 1000000.0,
			submitSeconds: metrics == null ? null : metrics.submitSeconds,
			styleResolutions: metrics == null ? null : metrics.styleResolutions,
			styleCacheHits: metrics == null ? null : metrics.styleCacheHits,
			styleCacheMisses: metrics == null ? null : metrics.styleCacheMisses,
			styleChangedNodes: metrics == null ? null : metrics.styleChangedNodes,
			viewSeconds: metrics == null ? null : metrics.viewSeconds,
			treeAndStyleSeconds: metrics == null ? null : metrics.treeAndStyleSeconds,
			nativeLayoutSeconds: metrics == null ? null : metrics.nativeLayoutSeconds,
			reconcileSeconds: metrics == null ? null : metrics.reconcileSeconds,
			renderSeconds: metrics == null ? null : metrics.renderSeconds,
			customPaintSeconds: metrics == null ? null : metrics.customPaintSeconds,
			nativeRenderSeconds: metrics == null ? null : metrics.nativeRenderSeconds,
			nodeCount: metrics == null ? null : metrics.nodeCount
		};
		timingRecorder.collect();
		if (presentation != null && presentation.frameId != null)
			timingRecorder.track(presentation, function(seconds) record.presentedMonotonicSeconds = seconds);
		frameHistory.push(record);
		record.bookkeepingSeconds = Sys.time() - frameFinishedAt;
		record.gcCollectionsTotal = Gc.collections();
		record.gcSecondsTotal = Gc.markMicros() / 1000000.0;
		record.gcCollections = record.gcCollectionsTotal - gcCountBefore;
		record.gcSeconds = record.gcSecondsTotal - gcMicrosBefore / 1000000.0;
	}

	public function needsFrames():Bool return options.frameLimit > 0;
	public function reachedFrameLimit():Bool return needsFrames() && readyFrames >= options.frameLimit;
	public function elapsed():Bool
		return startedAt >= 0.0 && options.captureSeconds > 0.0 && Sys.time() - startedAt >= options.captureSeconds;

	public function beginPoll(frames:Int):Void {
		measuring = startedAt >= 0.0;
		beginPhase(frames);
	}

	public function endPoll(frames:Int):Void {
		if (!measuring) return;
		backgroundStarted = Sys.time();
		loopTiming.loops++;
		loopTiming.pollSeconds += backgroundStarted - phaseStarted;
		loopTiming.pollFrameSeconds += callbackSeconds - callbackBeforePhase;
		loopTiming.pollFrames += frames - framesBeforePhase;
	}

	public function endBackground():Void {
		if (measuring) loopTiming.backgroundSeconds += Sys.time() - backgroundStarted;
	}

	public function beginWait(frames:Int):Void beginPhase(frames);

	public function endWait(frames:Int):Void {
		if (!measuring) return;
		loopTiming.waits++;
		loopTiming.waitSeconds += Sys.time() - phaseStarted;
		loopTiming.waitFrameSeconds += callbackSeconds - callbackBeforePhase;
		loopTiming.waitFrames += frames - framesBeforePhase;
	}

	function beginPhase(frames:Int):Void {
		if (!measuring) return;
		phaseStarted = Sys.time();
		callbackBeforePhase = callbackSeconds;
		framesBeforePhase = frames;
	}

	public function stopCensus():Void {
		if (!allocationCensusStarted) return;
		Gc.censusStop();
		allocationCensusStarted = false;
	}

	static function increment(counts:Map<String, Int>, key:String):Void {
		var previous = counts.get(key);
		counts.set(key, previous == null ? 1 : previous + 1);
	}

	/** Capture JSON names a function instead of failing on it (views may keep callbacks in inspected state). */
	static function noFunctions(_:Dynamic, value:Dynamic):Dynamic
		return Reflect.isFunction(value) ? "<function>" : value;

	public static function diagnosticState(application:Null<UiApplication>):Dynamic {
		if (!Std.isOfType(application, UiDiagnosticsProvider)) return null;
		var provider:UiDiagnosticsProvider = cast application;
		return provider.diagnosticState();
	}

	public function write(window:WindowHandle, state:UiHostRuntime):Void {
		var application = state.app();
		var renderer:Renderer = cast state.frameRenderer();
		var directory:String = cast options.captureDirectory;
		createDirectories(directory);
		if (Sys.getEnv("MATERIA_CAPTURE_ALLOCATIONS") == "1") {
			stopCensus();
			Gc.censusDump(directory + "/allocations.json");
		}
		File.saveContent(directory + "/ui-tree.txt", application.context().dumpTree() + "\n");
		File.saveContent(directory + "/layout.json",
			Json.stringify(application.context().inspect(), noFunctions, "  ") + "\n");
		File.saveContent(directory + "/app-state.json",
			Json.stringify(diagnosticState(application), noFunctions, "  ") + "\n");
		var metrics = application.context().frameMetrics;
		var stats = renderer.stats();
		var frameData:Dynamic = {
			logicalWidth: state.logicalWidth,
			logicalHeight: state.logicalHeight,
			framebufferWidth: state.framebufferWidth,
			framebufferHeight: state.framebufferHeight,
			pixelScale: state.scale,
			renderedFrames: state.rendered,
			ui: metrics == null ? null : {
				frameNumber: metrics.frameNumber, nodeCount: metrics.nodeCount,
				submitSeconds: metrics.submitSeconds, renderSeconds: metrics.renderSeconds,
				totalSeconds: metrics.totalSeconds, paintedNodes: metrics.paintedNodes,
				paintSkippedNodes: metrics.paintSkippedNodes, emptyPaintNodes: metrics.emptyPaintNodes,
				nativeLayoutSubmitted: metrics.nativeLayoutSubmitted,
				nativeLayoutReused: metrics.nativeLayoutReused
			},
			renderer: {
				pathPreparations: Std.string(stats.pathPreparations),
				pathCacheHits: Std.string(stats.pathCacheHits),
				pathCacheMisses: Std.string(stats.pathCacheMisses),
				rasterCacheHits: Std.string(stats.rasterCacheHits),
				rasterCacheMisses: Std.string(stats.rasterCacheMisses)
			},
			scheduling: {
				eventCounts: countsObject(eventCounts),
				frameRequestCounts: countsObject(frameRequestCounts),
				hostLoop: loopTiming
			}
		};
		File.saveContent(directory + "/frame-metrics.json",
			Json.stringify(frameData, null, "  ") + "\n");
		File.saveContent(directory + "/events.jsonl",
			[for (event in eventHistory) Json.stringify({event: event})].join("\n") + "\n");
		File.saveContent(directory + "/frame-timeline.jsonl",
			[for (frame in frameHistory) Json.stringify(frame)].join("\n") + "\n");
		if (Sys.systemName() == "Linux") {
			var nativeWindow = NativeKit.nk_window_get_native(window);
			if (nativeWindow.status != Result.Ok) {
				File.saveContent(directory + "/screenshot-error.txt", NativeKit.nk_last_error() + "\n");
			} else if (nativeWindow.out_native.get_kind() == NativeWindowKind.X11) {
				var xid = nativeWindow.out_native.get_window();
				var status = Sys.command("import", ["-window", Std.string(xid), directory + "/frame.png"]);
				if (status != 0)
					File.saveContent(directory + "/screenshot-error.txt",
						'ImageMagick import could not capture the application window (exit $status).\n');
			}
		}
		Sys.println("diagnostics captured in " + directory);
	}

	static function countsObject(counts:Map<String, Int>):Dynamic {
		var result:Dynamic = {};
		for (key in counts.keys()) {
			var value = counts.get(key);
			Reflect.setField(result, key, value == null ? 0 : value);
		}
		return result;
	}

	public static function createDirectories(path:String):Void {
		if (path == null || path.length == 0 || FileSystem.exists(path)) return;
		var slash = path.lastIndexOf("/");
		if (slash > 0) createDirectories(path.substr(0, slash));
		if (!FileSystem.exists(path)) FileSystem.createDirectory(path);
	}
}
