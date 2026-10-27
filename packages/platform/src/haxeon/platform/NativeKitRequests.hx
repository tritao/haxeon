package haxeon.platform;

import haxeon.platform.NativeKitEventValue.NativeKitResource;

import nativekit.ffi.NativeKit;
import nativekit.ffi.NativeKitTypes;
import haxeon.platform.NativeKitEventValue;
import haxeon.platform.NativeKitRequestOutcome;
import haxeon.platform.NativeKitWebView;
import haxeon.platform.NativeKitWindow;

/** Maps asynchronous NativeKit request IDs to one-shot typed completions. */
class NativeKitRequests {
	final handlers:Map<String, NativeKitEventValue->Void> = [];
	final dialogCancellationRequested:Map<String, Bool> = [];
	var disposed:Bool = false;
	final shutdownHandlers:Map<String, Void->Void> = [];
	final taskShutdownHandlers:Map<String, Void->Void> = [];
	final taskHandlers:Map<String, NativeKitEventValue->Void> = [];

	@:allow(NativeKitEvents)
	private function new() {}

	/** Reads clipboard text; cancellation stops managed observation. */
	public function readClipboardText():NativeFuture<String> {
		ensureLive();
		var promise = new NativePromise<String>();
		var request = readClipboardTextCallback(function(outcome) promise.future.finish(outcome));
		promise.future.setCancellation(function() { forget(request); promise.cancel(); });
		return promise.future;
	}

	/** Reads clipboard files; cancellation stops managed observation. */
	public function readClipboardFiles():NativeFuture<Array<String>> {
		ensureLive();
		var promise = new NativePromise<Array<String>>();
		var request = readClipboardFilesCallback(function(outcome) promise.future.finish(outcome));
		promise.future.setCancellation(function() { forget(request); promise.cancel(); });
		return promise.future;
	}

	/** Reads structured clipboard resources; cancellation stops managed observation. */
	public function readClipboardResources():NativeFuture<Array<NativeKitResource>> {
		ensureLive();
		var promise = new NativePromise<Array<NativeKitResource>>();
		var request = readClipboardResourcesCallback(function(outcome) promise.future.finish(outcome));
		promise.future.setCancellation(function() { forget(request); promise.cancel(); });
		return promise.future;
	}

	/** Opens a resource chooser; cancellation waits for its native terminal event. */
	public function openResource(parent:NativeKitWindow, configured:FileDialogConfig):NativeFuture<Array<NativeKitResource>> {
		ensureLive();
		var promise = new NativePromise<Array<NativeKitResource>>();
		var request = openResourceCallback(parent, configured.nativeValue(), function(outcome) promise.future.finish(outcome));
		promise.future.setCancellation(function() { cancelDialog(request); });
		return promise.future;
	}

	/** Opens a save chooser; cancellation waits for its native terminal event. */
	public function saveResource(parent:NativeKitWindow, configured:FileDialogConfig):NativeFuture<Array<NativeKitResource>> {
		ensureLive();
		var promise = new NativePromise<Array<NativeKitResource>>();
		var request = saveResourceCallback(parent, configured.nativeValue(), function(outcome) promise.future.finish(outcome));
		promise.future.setCancellation(function() { cancelDialog(request); });
		return promise.future;
	}

	/** Chooses a directory; cancellation waits for its native terminal event. */
	public function selectResourceDirectory(parent:NativeKitWindow, configured:FileDialogConfig):NativeFuture<Array<NativeKitResource>> {
		ensureLive();
		var promise = new NativePromise<Array<NativeKitResource>>();
		var request = selectResourceDirectoryCallback(parent, configured.nativeValue(), function(outcome) promise.future.finish(outcome));
		promise.future.setCancellation(function() { cancelDialog(request); });
		return promise.future;
	}

	/** Commits a raw writable stream; Success(true) means a download was initiated. */
	public function commitResourceNative(stream:ResourceStreamHandle):NativeFuture<Bool> {
		ensureLive();
		var promise = new NativePromise<Bool>();
		var request = commitResourceCallback(stream, function(outcome) promise.future.finish(outcome));
		promise.future.setCancellation(function() { forget(request); promise.cancel(); });
		return promise.future;
	}

	/** Shows a message dialog; cancellation waits for its native terminal event. */
	public function messageDialog(parent:NativeKitWindow, options:MessageDialogConfig):NativeFuture<MessageResult> {
		ensureLive();
		var promise = new NativePromise<MessageResult>();
		var request = messageDialogCallback(parent, options.nativeValue(), function(outcome) promise.future.finish(outcome));
		promise.future.setCancellation(function() { cancelDialog(request); });
		return promise.future;
	}

	/** Evaluates script in a WebView; cancellation stops managed observation. */
	public function evaluateWebView(webview:NativeKitWebView, script:String):NativeFuture<String> {
		ensureLive();
		var promise = new NativePromise<String>();
		var request = evaluateWebViewCallback(webview, script, function(outcome) promise.future.finish(outcome));
		promise.future.setCancellation(function() { forget(request); promise.cancel(); });
		return promise.future;
	}

	/** Starts a clipboard-text read and tracks its typed completion. */
	public function readClipboardTextCallback(handler:NativeKitRequestOutcome<String>->Void):haxe.Int64 {
		ensureLive();
		var request = NativeKit.nk_clipboard_read_text_checked();
		track(request, function(value) switch value {
			case ClipboardText(_, result, text): handler(resultOutcome(result, text));
			case _: throw "NativeKit clipboard request completed with the wrong event";
		});
		shutdownHandlers.set(Std.string(request), function() handler(Cancelled));
		return request;
	}

	/** Starts a clipboard-file read and tracks its typed completion. */
	public function readClipboardFilesCallback(handler:NativeKitRequestOutcome<Array<String>>->Void):haxe.Int64 {
		ensureLive();
		var request = NativeKit.nk_clipboard_read_files_checked();
		track(request, function(value) switch value {
			case ClipboardFiles(_, result, paths): handler(resultOutcome(result, paths));
			case _: wrongEvent("clipboard file read");
		});
		shutdownHandlers.set(Std.string(request), function() handler(Cancelled));
		return request;
	}

	/** Starts a structured-resource clipboard read and tracks its typed completion. */
	public function readClipboardResourcesCallback(
		handler:NativeKitRequestOutcome<Array<NativeKitResource>>->Void):haxe.Int64 {
		ensureLive();
		var request = NativeKit.nk_clipboard_read_resources_checked();
		track(request, function(value) switch value {
			case Resources(_, _, result, _, items): handler(resultOutcome(result, items));
			case _: wrongEvent("clipboard resource read");
		});
		shutdownHandlers.set(Std.string(request), function() handler(Cancelled));
		return request;
	}

	public function openResourceCallback(parent:NativeKitWindow, configured:FileDialogOptions,
		handler:NativeKitRequestOutcome<Array<NativeKitResource>>->Void):haxe.Int64 {
		ensureLive();
		var request = NativeKit.nk_dialog_open_resource_checked(new Handle(parent.nativeHandle().rawValue()), configured);
		return trackResourceDialog("open-resource dialog", request, handler);
	}

	public function saveResourceCallback(parent:NativeKitWindow, configured:FileDialogOptions,
		handler:NativeKitRequestOutcome<Array<NativeKitResource>>->Void):haxe.Int64 {
		ensureLive();
		var request = NativeKit.nk_dialog_save_resource_checked(new Handle(parent.nativeHandle().rawValue()), configured);
		return trackResourceDialog("save-resource dialog", request, handler);
	}

	public function selectResourceDirectoryCallback(parent:NativeKitWindow, configured:FileDialogOptions,
		handler:NativeKitRequestOutcome<Array<NativeKitResource>>->Void):haxe.Int64 {
		ensureLive();
		var request = NativeKit.nk_dialog_select_resource_directory_checked(new Handle(parent.nativeHandle().rawValue()), configured);
		return trackResourceDialog("resource-directory dialog", request, handler);
	}

	/** Commits a writable stream; Success(true) means a download was only initiated. */
	public function commitResourceCallback(stream:ResourceStreamHandle,
		handler:NativeKitRequestOutcome<Bool>->Void):haxe.Int64 {
		ensureLive();
		var request = NativeKit.nk_resource_commit_checked(stream);
		track(request, function(value) switch value {
			case ResourceCommit(_, result, downloadInitiated):
				handler(resultOutcome(result, downloadInitiated));
			case _: wrongEvent("resource commit");
		});
		shutdownHandlers.set(Std.string(request), function() handler(Cancelled));
		return request;
	}

	public function messageDialogCallback(parent:NativeKitWindow, options:MessageDialogOptions,
		handler:NativeKitRequestOutcome<MessageResult>->Void):haxe.Int64 {
		ensureLive();
		var request = NativeKit.nk_dialog_message_checked(new Handle(parent.nativeHandle().rawValue()), options);
		trackDialogRequest(request, function(value, cancellationRequested) switch value {
			case DialogMessage(_, result, button):
				handler(messageOutcome(result, button, cancellationRequested));
			case _: wrongEvent("message dialog");
		});
		shutdownHandlers.set(Std.string(request), function() handler(Cancelled));
		return request;
	}

	public function evaluateWebViewCallback(webview:NativeKitWebView, script:String,
		handler:NativeKitRequestOutcome<String>->Void):haxe.Int64 {
		ensureLive();
		var request = NativeKit.nk_webview_eval_checked(webview.nativeHandle(), script);
		track(request, function(value) switch value {
			case WebViewEvaluation(_, _, result, json):
				handler(resultOutcome(result, json, result == Result.Ok ? null : json));
			case _: wrongEvent("WebView evaluation");
		});
		shutdownHandlers.set(Std.string(request), function() handler(Cancelled));
		return request;
	}

	public function track(request:haxe.Int64, handler:NativeKitEventValue->Void, ?onShutdown:Void->Void):Void {
		ensureLive();
		var key = Std.string(request);
		if (handlers.exists(key)) throw "NativeKit request is already tracked";
		handlers.set(key, handler);
		if (onShutdown != null) shutdownHandlers.set(key, onShutdown);
	}

	/** Cancels a tracked native dialog while retaining its terminal completion. */
	public function cancelDialog(request:haxe.Int64):Bool {
		var key = Std.string(request);
		if (!handlers.exists(key) || !dialogCancellationRequested.exists(key)
			|| dialogCancellationRequested.get(key))
			return false;
		NativeKit.nk_dialog_cancel_checked(request);
		dialogCancellationRequested.set(key, true);
		return true;
	}

	/** Stops dispatching a completion without cancelling native work. */
	public function forget(request:haxe.Int64):Bool {
		var key = Std.string(request);
		dialogCancellationRequested.remove(key);
		shutdownHandlers.remove(key);
		return handlers.remove(key);
	}

	/** Tracks a native task without installing a managed worker callback. */
	public function trackTask<T>(task:NativeTask, decode:haxe.io.Bytes->T):NativeFuture<T> {
		ensureLive();
		var promise = new NativePromise<T>();
		var key = Std.string(task.nativeHandle().rawValue());
		if (taskHandlers.exists(key)) throw "NativeKit task is already tracked";
		promise.future.setCancellation(function() {
			task.cancel();
		});
		taskShutdownHandlers.set(key, function() promise.cancel());
		taskHandlers.set(key, function(value) switch value {
			case TaskProgress(_, _): return;
			case TaskComplete(_, result, data):
				if (result == Result.Ok) {
					var decoded:T;
					try decoded = decode(data) catch (error:Dynamic) {
						promise.fail(Result.ErrorUnknown, Std.string(error));
						return;
					}
					promise.complete(decoded);
				} else promise.fail(result, null);
			case TaskFailed(_, result, _): promise.fail(result, null);
			case TaskCancelled(_, _, _): promise.cancel();
			case _: throw "NativeKit task completed with the wrong event";
		});
		return promise.future;
	}

	/** Routes a decoded event to its matching one-shot request handler. */
	public function handle(value:NativeKitEventValue):Bool {
		ensureLive();
		var key = requestKey(value);
		var handler = key == null ? null : handlers.get(key);
		if (handler != null) {
			handlers.remove(key);
			shutdownHandlers.remove(key);
			handler(value);
			return true;
		}
		var taskKey:Null<String> = switch value {
			case TaskProgress(source, _): Std.string(source.rawValue());
			case TaskComplete(source, _, _): Std.string(source.rawValue());
			case TaskFailed(source, _, _): Std.string(source.rawValue());
			case TaskCancelled(source, _, _): Std.string(source.rawValue());
			case _: null;
		};
		if (taskKey == null)
			return false;
		handler = taskHandlers.get(taskKey);
		if (handler == null)
			return false;
		var terminal = switch value {
			case TaskComplete(_, _, _) | TaskFailed(_, _, _) | TaskCancelled(_, _, _): true;
			case _: false;
		};
		if (terminal) {
			taskHandlers.remove(taskKey);
			taskShutdownHandlers.remove(taskKey);
		}
		handler(value);
		return true;
	}

	/** Completes all managed operations when their owning runtime ends. */
	@:allow(NativeKitEvents)
	function runtimeShutdown():Void {
		if (disposed) return;
		disposed = true;
		var callbacks:Array<Void->Void> = [];
		for (callback in shutdownHandlers) callbacks.push(callback);
		for (callback in taskShutdownHandlers) callbacks.push(callback);
		handlers.clear();
		taskHandlers.clear();
		shutdownHandlers.clear();
		taskShutdownHandlers.clear();
		dialogCancellationRequested.clear();
		var failure:Dynamic = null;
		for (callback in callbacks) try callback() catch (error:Dynamic) {
			if (failure == null) failure = error;
		}
		if (failure != null) throw failure;
	}

	function ensureLive():Void {
		if (disposed) throw "NativeKit requests have been disposed with their runtime";
	}

	public function pending():Int {
		var count = 0;
		for (_ in handlers) count++;
		for (_ in taskHandlers) count++;
		return count;
	}

	function trackResourceDialog(name:String, request:haxe.Int64,
		handler:NativeKitRequestOutcome<Array<NativeKitResource>>->Void):haxe.Int64 {
		trackDialogRequest(request, function(value, _cancellationRequested) switch value {
			case Resources(kind, _, result, accepted, items):
				if (kind != EventKind.DialogResourcesComplete) wrongEvent(name);
				handler(acceptedOutcome(result, accepted, items));
			case _: wrongEvent(name);
		});
		shutdownHandlers.set(Std.string(request), function() handler(Cancelled));
		return request;
	}

	function trackDialogRequest(request:haxe.Int64,
		handler:NativeKitEventValue->Bool->Void):Void {
		var key = Std.string(request);
		track(request, function(value) {
			var cancellationRequested = dialogCancellationRequested.get(key) == true;
			dialogCancellationRequested.remove(key);
			handler(value, cancellationRequested);
		});
		dialogCancellationRequested.set(key, false);
	}

	static function requestKey(value:NativeKitEventValue):Null<String> {
		var key:Null<String> = switch value {
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
		return key == "0" ? null : key;
	}

	static function resultOutcome<T>(result:Result, value:T,
		?message:Null<String>):NativeKitRequestOutcome<T> {
		return result == Result.Ok ? Success(value) : result == Result.ErrorCancelled ? Cancelled : Failure(result, message);
	}

	static function acceptedOutcome<T>(result:Result, accepted:Bool,
		value:T):NativeKitRequestOutcome<T> {
		if (result == Result.ErrorCancelled) return Cancelled;
		if (result != Result.Ok)
			return Failure(result, null);
		return accepted ? Success(value) : Cancelled;
	}

	static function messageOutcome(result:Result, button:MessageResult,
		cancellationRequested:Bool):NativeKitRequestOutcome<MessageResult> {
		if (result == Result.ErrorCancelled) return Cancelled;
		if (result != Result.Ok)
			return Failure(result, null);
		return cancellationRequested || button == MessageResult.None ? Cancelled : Success(button);
	}

	static function wrongEvent(name:String):Void
		throw 'NativeKit $name completed with the wrong event';
}
