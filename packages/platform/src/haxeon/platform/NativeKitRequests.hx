package haxeon.platform;

import haxeon.platform.NativeKitEventValue.NativeKitResource;
import nativekit.ffi.NativeKit;
import nativekit.ffi.NativeKitTypes;

/** One registry owns completion, cancellation, and detachment for every request and task. */
class NativeKitRequests {
	final entries:Map<String, NativeRequestEntry> = [];
	var disposed:Bool = false;

	@:allow(NativeKitEvents)
	private function new() {}

	public function readClipboardText():NativeFuture<String> {
		ensureLive();
		return registerRequest(NativeKit.nk_clipboard_read_text_checked(), function(value, _) switch value {
			case ClipboardText(_, result, text): resultOutcome(result, text, "NativeKitRequests.readClipboardText");
			case _: wrongEvent("clipboard text read");
		});
	}

	public function readClipboardFiles():NativeFuture<Array<String>> {
		ensureLive();
		return registerRequest(NativeKit.nk_clipboard_read_files_checked(), function(value, _) switch value {
			case ClipboardFiles(_, result, paths): resultOutcome(result, paths, "NativeKitRequests.readClipboardFiles");
			case _: wrongEvent("clipboard file read");
		});
	}

	public function readClipboardResources():NativeFuture<Array<NativeKitResource>> {
		ensureLive();
		return registerRequest(NativeKit.nk_clipboard_read_resources_checked(), function(value, _) switch value {
			case Resources(_, _, result, _, items): resultOutcome(result, items, "NativeKitRequests.readClipboardResources");
			case _: wrongEvent("clipboard resource read");
		});
	}

	public function openResource(parent:NativeKitWindow, options:FileDialogConfig):NativeFuture<Array<NativeKitResource>> {
		ensureLive();
		if (parent == null || options == null) throw BindingError.invalidArgument("NativeKitRequests.openResource", "Parent and options cannot be null");
		return resourceDialog(NativeKit.nk_dialog_open_resource_checked(new Handle(parent.nativeHandle().rawValue()), options.nativeValue()));
	}

	public function saveResource(parent:NativeKitWindow, options:FileDialogConfig):NativeFuture<Array<NativeKitResource>> {
		ensureLive();
		if (parent == null || options == null) throw BindingError.invalidArgument("NativeKitRequests.saveResource", "Parent and options cannot be null");
		return resourceDialog(NativeKit.nk_dialog_save_resource_checked(new Handle(parent.nativeHandle().rawValue()), options.nativeValue()));
	}

	public function selectResourceDirectory(parent:NativeKitWindow, options:FileDialogConfig):NativeFuture<Array<NativeKitResource>> {
		ensureLive();
		if (parent == null || options == null) throw BindingError.invalidArgument("NativeKitRequests.selectResourceDirectory", "Parent and options cannot be null");
		return resourceDialog(NativeKit.nk_dialog_select_resource_directory_checked(new Handle(parent.nativeHandle().rawValue()), options.nativeValue()));
	}

	/** Commits a raw writable stream; Success(true) means a download was initiated. */
	public function commitResourceNative(stream:ResourceStreamHandle):NativeFuture<Bool> {
		ensureLive();
		return registerRequest(NativeKit.nk_resource_commit_checked(stream), function(value, _) switch value {
			case ResourceCommit(_, result, downloadInitiated): resultOutcome(result, downloadInitiated, "NativeKitRequests.commitResourceNative");
			case _: wrongEvent("resource commit");
		});
	}

	public function messageDialog(parent:NativeKitWindow, options:MessageDialogConfig):NativeFuture<MessageResult> {
		ensureLive();
		if (parent == null || options == null) throw BindingError.invalidArgument("NativeKitRequests.messageDialog", "Parent and options cannot be null");
		var request = NativeKit.nk_dialog_message_checked(new Handle(parent.nativeHandle().rawValue()), options.nativeValue());
		return registerRequest(request, function(value, cancellationRequested) switch value {
			case DialogMessage(_, result, button): messageOutcome(result, button, cancellationRequested);
			case _: wrongEvent("message dialog");
		}, function() NativeKit.nk_dialog_cancel_checked(request));
	}

	public function evaluateWebView(webview:NativeKitWebView, script:String):NativeFuture<String> {
		ensureLive();
		if (webview == null || script == null) throw BindingError.invalidArgument("NativeKitRequests.evaluateWebView", "WebView and script cannot be null");
		return registerRequest(NativeKit.nk_webview_eval_checked(webview.nativeHandle(), script), function(value, _) switch value {
			case WebViewEvaluation(_, _, result, json): resultOutcome(result, json, "NativeKitRequests.evaluateWebView", result == Result.Ok ? null : json);
			case _: wrongEvent("WebView evaluation");
		});
	}

	/** Explicit interop for a native request; decoder failures become terminal Failure outcomes. */
	public function trackNative<T>(request:haxe.Int64, decode:NativeKitEventValue->NativeKitRequestOutcome<T>,
		?cancelNative:Void->Void):NativeFuture<T> {
		ensureLive();
		if (decode == null) throw BindingError.invalidArgument("NativeKitRequests.trackNative", "Decoder cannot be null");
		return registerRequest(request, function(value, _) return decode(value), cancelNative);
	}

	/** Observes a native task without installing a managed worker callback. The caller owns the task. */
	public function trackTask<T>(task:NativeTask, decode:haxe.io.Bytes->T):NativeFuture<T> {
		ensureLive();
		if (task == null || decode == null) throw BindingError.invalidArgument("NativeKitRequests.trackTask", "Task and decoder cannot be null");
		return register("task:" + Std.string(task.nativeHandle().rawValue()), function(value, _) switch value {
			case TaskComplete(_, result, data):
				// register() catches decoder exceptions separately from completion-observer exceptions.
				if (result == Result.Ok) Success(decode(data));
				else if (result == Result.ErrorCancelled) Cancelled;
				else Failure(new NativeKitError(result, "NativeKitRequests.trackTask", null));
			case TaskFailed(_, result, _): Failure(new NativeKitError(result, "NativeKitRequests.trackTask", null));
			case TaskCancelled(_, _, _): Cancelled;
			case _: wrongEvent("task");
		}, task.cancel);
	}

	function resourceDialog(request:haxe.Int64):NativeFuture<Array<NativeKitResource>> {
		return registerRequest(request, function(value, _) switch value {
			case Resources(EventKind.DialogResourcesComplete, _, result, accepted, items): acceptedOutcome(result, accepted, items);
			case _: wrongEvent("resource dialog");
		}, function() NativeKit.nk_dialog_cancel_checked(request));
	}

	function registerRequest<T>(request:haxe.Int64, decode:NativeKitEventValue->Bool->NativeKitRequestOutcome<T>,
		?cancelNative:Void->Void):NativeFuture<T> {
		if (request == haxe.Int64.ofInt(0)) throw BindingError.invalidArgument("NativeKitRequests.registerRequest", "Request ID cannot be zero");
		return register("request:" + Std.string(request), decode, cancelNative);
	}

	function register<T>(key:String, decode:NativeKitEventValue->Bool->NativeKitRequestOutcome<T>,
		cancelNative:Null<Void->Void>):NativeFuture<T> {
		ensureLive();
		if (entries.exists(key)) throw BindingError.invalidState("NativeKitRequests.register", "Operation is already tracked");
		var promise = new NativePromise<T>();
		var entry = new NativeRequestEntry(function(value) {
			var outcome:NativeKitRequestOutcome<T>;
			try {
				outcome = decode(value, promise.future.isCancellationRequested());
				if (outcome == null) throw BindingError.invalidData("NativeKitRequests.decode", "Decoder returned null");
			} catch (error:NativeError) {
				promise.fail(error);
				return;
			} catch (error:Dynamic) {
				promise.fail(BindingError.invalidData("NativeKitRequests.decode", Std.string(error)));
				return;
			}
			promise.resolve(outcome);
		}, promise.cancel);
		entries.set(key, entry);
		promise.future.setControls(cancelNative, function() {
			if (entries.get(key) == entry) entries.remove(key);
		});
		return promise.future;
	}

	/** Detaches a terminal entry before invoking observers, allowing safe reentrant tracking. */
	public function handle(value:NativeKitEventValue):Bool {
		ensureLive();
		var key = eventKey(value);
		if (key == null) return false;
		var entry = entries.get(key);
		if (entry == null) return false;
		switch value {
			case TaskProgress(_, _): return true;
			case _:
		}
		entries.remove(key);
		entry.receive(value);
		return true;
	}

	@:allow(NativeKitEvents)
	function runtimeShutdown():Void {
		if (disposed) return;
		disposed = true;
		var pending = [for (entry in entries) entry];
		entries.clear();
		var failure:Dynamic = null;
		for (entry in pending) try entry.shutdown() catch (error:Dynamic) {
			if (failure == null) failure = error;
		}
		if (failure != null) throw failure;
	}

	public function pending():Int {
		var count = 0;
		for (_ in entries) count++;
		return count;
	}

	function ensureLive():Void {
		if (disposed) throw BindingError.disposed("NativeKitRequests", "Requests have been disposed with their runtime");
	}

	static function eventKey(value:NativeKitEventValue):Null<String> {
		var key:Null<String> = switch value {
			case TaskProgress(source, _) | TaskComplete(source, _, _) | TaskFailed(source, _, _) | TaskCancelled(source, _, _):
				return "task:" + Std.string(source.rawValue());
			case ClipboardText(id, _, _): Std.string(id);
			case ClipboardFiles(id, _, _): Std.string(id);
			case DialogMessage(id, _, _): Std.string(id);
			case WebViewEvaluation(_, id, _, _): Std.string(id);
			case WebViewNavigationRequest(_, id, _): Std.string(id);
			case NotificationActivated(id, _): Std.string(id);
			case NotificationFailed(id, _): Std.string(id);
			case Resources(_, id, _, _, _): Std.string(id);
			case ResourceAssetReady(_, id): Std.string(id);
			case ResourceAssetLoadFailed(_, id, _): Std.string(id);
			case ResourceCommit(id, _, _): Std.string(id);
			// nk_resource_load_async completes with the loaded bytes in a raw event.
			case Raw(kind, _, id, _, _, _, _) if (kind == EventKind.ResourceDataComplete): Std.string(id);
			case _: null;
		};
		return key == null || key == "0" ? null : "request:" + key;
	}

	static function resultOutcome<T>(result:Result, value:T, operation:String,
		?message:Null<String>):NativeKitRequestOutcome<T> {
		return result == Result.Ok ? Success(value) : result == Result.ErrorCancelled ? Cancelled : Failure(new NativeKitError(result, operation, message));
	}

	static function acceptedOutcome<T>(result:Result, accepted:Bool,
		value:T):NativeKitRequestOutcome<T> {
		if (result == Result.ErrorCancelled) return Cancelled;
		if (result != Result.Ok)
			return Failure(new NativeKitError(result, "NativeKitRequests.resourceDialog", null));
		return accepted ? Success(value) : Cancelled;
	}

	static function messageOutcome(result:Result, button:MessageResult,
		cancellationRequested:Bool):NativeKitRequestOutcome<MessageResult> {
		if (result == Result.ErrorCancelled) return Cancelled;
		if (result != Result.Ok)
			return Failure(new NativeKitError(result, "NativeKitRequests.messageDialog", null));
		return cancellationRequested || button == MessageResult.None ? Cancelled : Success(button);
	}

	static function wrongEvent<T>(name:String):NativeKitRequestOutcome<T>
		throw BindingError.invalidData("NativeKitRequests.decode", 'NativeKit $name completed with the wrong event');
}

/** The registry owns one delivery path and one shutdown path per operation. */
private class NativeRequestEntry {
	public final receive:NativeKitEventValue->Void;
	public final shutdown:Void->Void;

	public function new(receive:NativeKitEventValue->Void, shutdown:Void->Void) {
		this.receive = receive;
		this.shutdown = shutdown;
	}
}
