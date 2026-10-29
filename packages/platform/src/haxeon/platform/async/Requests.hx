package haxeon.platform.async;

import haxeon.platform.BindingError;
import haxeon.platform.NativeKitError;
import haxeon.platform.PlatformError;
import haxeon.platform.WebView;
import haxeon.platform.Window;
import haxeon.platform.async.Future;
import haxeon.platform.async.Outcome;
import haxeon.platform.async.Promise;
import haxeon.platform.async.Task;
import haxeon.platform.dialog.FileDialogOptions;
import haxeon.platform.dialog.MessageDialogOptions;
import haxeon.platform.event.EventPump;
import haxeon.platform.event.PlatformEvent;
import haxeon.platform.resource.Resource;
import nativekit.ffi.NativeKit;
import nativekit.ffi.NativeKitTypes.EventKind;
import nativekit.ffi.NativeKitTypes.Handle;
import nativekit.ffi.NativeKitTypes.MessageResult;
import nativekit.ffi.NativeKitTypes.ResourceStreamHandle;
import nativekit.ffi.NativeKitTypes.Result;

/** One registry owns completion, cancellation, and detachment for every request and task. */
class Requests {
	final entries:Map<String, NativeRequestEntry> = [];
	var disposed:Bool = false;

	@:allow(EventPump)
	private function new() {}

	public function readClipboardText():Future<String> {
		ensureLive();
		return registerRequest(NativeKit.nk_clipboard_read_text_checked(), function(value, _) switch value {
			case ClipboardText(_, result, text): resultOutcome(result, text, "Requests.readClipboardText");
			case _: wrongEvent("clipboard text read");
		});
	}

	public function readClipboardFiles():Future<Array<String>> {
		ensureLive();
		return registerRequest(NativeKit.nk_clipboard_read_files_checked(), function(value, _) switch value {
			case ClipboardFiles(_, result, paths): resultOutcome(result, paths, "Requests.readClipboardFiles");
			case _: wrongEvent("clipboard file read");
		});
	}

	public function readClipboardResources():Future<Array<Resource>> {
		ensureLive();
		return registerRequest(NativeKit.nk_clipboard_read_resources_checked(), function(value, _) switch value {
			case Resources(_, _, result, _, items): resultOutcome(result, items, "Requests.readClipboardResources");
			case _: wrongEvent("clipboard resource read");
		});
	}

	public function openResource(parent:Window, options:FileDialogOptions):Future<Array<Resource>> {
		ensureLive();
		if (parent == null || options == null) throw BindingError.invalidArgument("Requests.openResource", "Parent and options cannot be null");
		return resourceDialog(NativeKit.nk_dialog_open_resource_checked(new Handle(parent.nativeHandle().rawValue()), options.nativeValue()));
	}

	public function saveResource(parent:Window, options:FileDialogOptions):Future<Array<Resource>> {
		ensureLive();
		if (parent == null || options == null) throw BindingError.invalidArgument("Requests.saveResource", "Parent and options cannot be null");
		return resourceDialog(NativeKit.nk_dialog_save_resource_checked(new Handle(parent.nativeHandle().rawValue()), options.nativeValue()));
	}

	public function selectResourceDirectory(parent:Window, options:FileDialogOptions):Future<Array<Resource>> {
		ensureLive();
		if (parent == null || options == null) throw BindingError.invalidArgument("Requests.selectResourceDirectory", "Parent and options cannot be null");
		return resourceDialog(NativeKit.nk_dialog_select_resource_directory_checked(new Handle(parent.nativeHandle().rawValue()), options.nativeValue()));
	}

	/** Commits a raw writable stream; Success(true) means a download was initiated. */
	public function commitResourceNative(stream:ResourceStreamHandle):Future<Bool> {
		ensureLive();
		return registerRequest(NativeKit.nk_resource_commit_checked(stream), function(value, _) switch value {
			case ResourceCommit(_, result, downloadInitiated): resultOutcome(result, downloadInitiated, "Requests.commitResourceNative");
			case _: wrongEvent("resource commit");
		});
	}

	public function messageDialog(parent:Window, options:MessageDialogOptions):Future<MessageResult> {
		ensureLive();
		if (parent == null || options == null) throw BindingError.invalidArgument("Requests.messageDialog", "Parent and options cannot be null");
		var request = NativeKit.nk_dialog_message_checked(new Handle(parent.nativeHandle().rawValue()), options.nativeValue());
		return registerRequest(request, function(value, cancellationRequested) switch value {
			case DialogMessage(_, result, button, _): messageOutcome(result, button, cancellationRequested);
			case _: wrongEvent("message dialog");
		}, function() NativeKit.nk_dialog_cancel_checked(request));
	}

	public function evaluateWebView(webview:WebView, script:String):Future<String> {
		ensureLive();
		if (webview == null || script == null) throw BindingError.invalidArgument("Requests.evaluateWebView", "WebView and script cannot be null");
		return registerRequest(NativeKit.nk_webview_eval_checked(webview.nativeHandle(), script), function(value, _) switch value {
			case WebViewEvaluation(_, _, result, json): resultOutcome(result, json, "Requests.evaluateWebView", result == Result.Ok ? null : json);
			case _: wrongEvent("WebView evaluation");
		});
	}

	/** Explicit interop for a native request; decoder failures become terminal Failure outcomes. */
	public function trackNative<T>(request:haxe.Int64, decode:PlatformEvent->Outcome<T>,
		?cancelNative:Void->Void):Future<T> {
		ensureLive();
		if (decode == null) throw BindingError.invalidArgument("Requests.trackNative", "Decoder cannot be null");
		return registerRequest(request, function(value, _) return decode(value), cancelNative);
	}

	/** Observes a native task without installing a managed worker callback. The caller owns the task. */
	public function trackTask<T>(task:Task, decode:haxe.io.Bytes->T):Future<T> {
		ensureLive();
		if (task == null || decode == null) throw BindingError.invalidArgument("Requests.trackTask", "Task and decoder cannot be null");
		return register("task:" + Std.string(task.nativeHandle().rawValue()), function(value, _) switch value {
			case TaskComplete(_, result, data):
				// register() catches decoder exceptions separately from completion-observer exceptions.
				if (result == Result.Ok) Success(decode(data));
				else if (result == Result.ErrorCancelled) Cancelled;
				else Failure(new NativeKitError(result, "Requests.trackTask", null));
			case TaskFailed(_, result, _): Failure(new NativeKitError(result, "Requests.trackTask", null));
			case TaskCancelled(_, _, _): Cancelled;
			case _: wrongEvent("task");
		}, task.cancel);
	}

	function resourceDialog(request:haxe.Int64):Future<Array<Resource>> {
		return registerRequest(request, function(value, _) switch value {
			case Resources(EventKind.DialogResourcesComplete, _, result, accepted, items): acceptedOutcome(result, accepted, items);
			case _: wrongEvent("resource dialog");
		}, function() NativeKit.nk_dialog_cancel_checked(request));
	}

	function registerRequest<T>(request:haxe.Int64, decode:PlatformEvent->Bool->Outcome<T>,
		?cancelNative:Void->Void):Future<T> {
		if (request == haxe.Int64.ofInt(0)) throw BindingError.invalidArgument("Requests.registerRequest", "Request ID cannot be zero");
		return register("request:" + Std.string(request), decode, cancelNative);
	}

	function register<T>(key:String, decode:PlatformEvent->Bool->Outcome<T>,
		cancelNative:Null<Void->Void>):Future<T> {
		ensureLive();
		if (entries.exists(key)) throw BindingError.invalidState("Requests.register", "Operation is already tracked");
		var promise = new Promise<T>();
		var entry = new NativeRequestEntry(function(value) {
			var outcome:Outcome<T>;
			try {
				outcome = decode(value, promise.future.isCancellationRequested());
				if (outcome == null) throw BindingError.invalidData("Requests.decode", "Decoder returned null");
			} catch (error:PlatformError) {
				promise.fail(error);
				return;
			} catch (error:Dynamic) {
				promise.fail(BindingError.invalidData("Requests.decode", Std.string(error)));
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
	public function handle(value:PlatformEvent):Bool {
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

	@:allow(EventPump)
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
		if (disposed) throw BindingError.disposed("Requests", "Requests have been disposed with their runtime");
	}

	static function eventKey(value:PlatformEvent):Null<String> {
		var key:Null<String> = switch value {
			case TaskProgress(source, _) | TaskComplete(source, _, _) | TaskFailed(source, _, _) | TaskCancelled(source, _, _):
				return "task:" + Std.string(source.rawValue());
			case ClipboardText(id, _, _): Std.string(id);
			case ClipboardFiles(id, _, _): Std.string(id);
			case DialogMessage(id, _, _, _): Std.string(id);
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
		?message:Null<String>):Outcome<T> {
		return result == Result.Ok ? Success(value) : result == Result.ErrorCancelled ? Cancelled : Failure(new NativeKitError(result, operation, message));
	}

	static function acceptedOutcome<T>(result:Result, accepted:Bool,
		value:T):Outcome<T> {
		if (result == Result.ErrorCancelled) return Cancelled;
		if (result != Result.Ok)
			return Failure(new NativeKitError(result, "Requests.resourceDialog", null));
		return accepted ? Success(value) : Cancelled;
	}

	static function messageOutcome(result:Result, button:MessageResult,
		cancellationRequested:Bool):Outcome<MessageResult> {
		if (result == Result.ErrorCancelled) return Cancelled;
		if (result != Result.Ok)
			return Failure(new NativeKitError(result, "Requests.messageDialog", null));
		return cancellationRequested || button == MessageResult.None ? Cancelled : Success(button);
	}

	static function wrongEvent<T>(name:String):Outcome<T>
		throw BindingError.invalidData("Requests.decode", 'NativeKit $name completed with the wrong event');
}

/** The registry owns one delivery path and one shutdown path per operation. */
private class NativeRequestEntry {
	public final receive:PlatformEvent->Void;
	public final shutdown:Void->Void;

	public function new(receive:PlatformEvent->Void, shutdown:Void->Void) {
		this.receive = receive;
		this.shutdown = shutdown;
	}
}
