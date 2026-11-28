package haxeon.platform.async;

import haxeon.async.Future;
import haxeon.async.Outcome;
import haxeon.async.Promise;
import haxeon.platform.BindingError;
import haxeon.platform.NativeKitError;
import haxeon.platform.WebView;
import haxeon.platform.Window;
import haxeon.platform.async.Task;
import haxeon.platform.dialog.FileDialogOptions;
import haxeon.platform.dialog.MessageAnswer;
import haxeon.platform.dialog.MessageDialogOptions;
import haxeon.platform.async.Completion;
import haxeon.platform.event.Delivery;
import haxeon.platform.event.EventPump;
import haxeon.platform.event.PlatformEvent;
import haxeon.platform.resource.Resource;
import nativekit.ffi.NativeKit;
import nativekit.ffi.NativeKitTypes.EventKind;
import nativekit.ffi.NativeKitTypes.Handle;
import nativekit.ffi.NativeKitTypes.MessageResult;
import nativekit.ffi.NativeKitTypes.ResourceStreamHandle;

/** One registry owns completion, cancellation, and detachment for every request and task. */
class Requests {
	final entries:Map<String, NativeRequestEntry> = [];
	var disposed:Bool = false;

	@:allow(haxeon.platform.event.EventPump)
	private function new() {}

	/** Reads the clipboard's text. */
	public function readClipboardText():Future<Result<String, NativeKitError>> {
		ensureLive();
		return registerRequest(NativeKit.nk_clipboard_read_text_checked(), (value, _) -> switch value {
			case Answered(ClipboardText(_, text)): settled(text);
			case _: wrongEvent("clipboard text read");
		});
	}

	/** Reads the clipboard's file paths. */
	public function readClipboardFiles():Future<Result<Array<String>, NativeKitError>> {
		ensureLive();
		return registerRequest(NativeKit.nk_clipboard_read_files_checked(), (value, _) -> switch value {
			case Answered(ClipboardFiles(_, paths)): settled(paths);
			case _: wrongEvent("clipboard file read");
		});
	}

	/** Reads the clipboard's resources. */
	public function readClipboardResources():Future<Result<Array<Resource>, NativeKitError>> {
		ensureLive();
		return registerRequest(NativeKit.nk_clipboard_read_resources_checked(), (value, _) -> switch value {
			case Answered(ClipboardResources(_, items)): settled(items);
			case _: wrongEvent("clipboard resource read");
		});
	}

	/** Asks the user to pick resources to open. */
	public function openResource(parent:Window,
			options:FileDialogOptions):Future<Result<Array<Resource>, NativeKitError>> {
		ensureLive();
		if (parent == null || options == null) throw BindingError.invalidArgument("Requests.openResource",
			"Parent and options cannot be null");
		return resourceDialog(NativeKit.nk_dialog_open_resource_checked(new Handle(parent.nativeHandle().rawValue),
			options.nativeValue()));
	}

	/** Asks the user where to save. */
	public function saveResource(parent:Window,
			options:FileDialogOptions):Future<Result<Array<Resource>, NativeKitError>> {
		ensureLive();
		if (parent == null || options == null) throw BindingError.invalidArgument("Requests.saveResource",
			"Parent and options cannot be null");
		return resourceDialog(NativeKit.nk_dialog_save_resource_checked(new Handle(parent.nativeHandle().rawValue),
			options.nativeValue()));
	}

	/** Asks the user to pick a directory. */
	public function selectResourceDirectory(parent:Window,
			options:FileDialogOptions):Future<Result<Array<Resource>, NativeKitError>> {
		ensureLive();
		if (parent == null || options == null) throw BindingError.invalidArgument("Requests.selectResourceDirectory",
			"Parent and options cannot be null");
		return resourceDialog(NativeKit.nk_dialog_select_resource_directory_checked(new Handle(parent.nativeHandle()
			.rawValue), options.nativeValue()));
	}

	/** Reads all of `resource`'s bytes; cancelling the future stops the load. */
	public function loadResource(resource:Resource):Future<Result<haxe.io.Bytes, NativeKitError>> {
		ensureLive();
		if (resource == null) throw BindingError.invalidArgument("Requests.loadResource", "Resource cannot be null");
		var request = NativeKit.nk_resource_load_async_checked(resource.nativeValue());
		return registerRequest(request, (value, _) -> switch value {
			case Answered(ResourceData(_, bytes)): settled(bytes);
			case _: wrongEvent("resource load");
		}, () -> NativeKit.nk_resource_load_cancel_checked(request));
	}

	/** Commits a raw writable stream; `Ok(true)` means a download was initiated. */
	public function commitResourceNative(stream:ResourceStreamHandle):Future<Result<Bool, NativeKitError>> {
		ensureLive();
		return registerRequest(NativeKit.nk_resource_commit_checked(stream), (value, _) -> switch value {
			case Answered(ResourceCommit(_, downloadInitiated)): settled(downloadInitiated);
			case _: wrongEvent("resource commit");
		});
	}

	/** Shows a message dialog and resolves with the button chosen, and its checkbox's state. */
	public function messageDialog(parent:Window,
			options:MessageDialogOptions):Future<Result<MessageAnswer, NativeKitError>> {
		ensureLive();
		if (parent == null || options == null) throw BindingError.invalidArgument("Requests.messageDialog",
			"Parent and options cannot be null");
		var request = NativeKit.nk_dialog_message_checked(new Handle(parent.nativeHandle().rawValue),
			options.nativeValue());
		return registerRequest(request, (value, cancellationRequested) -> switch value {
			case Answered(DialogMessage(_, answer)): cancellationRequested ? Outcome.Cancelled : settled(answer);
			case _: wrongEvent("message dialog");
		}, () -> NativeKit.nk_dialog_cancel_checked(request));
	}

	/** Runs `script` in a web view and resolves with its result as JSON. */
	public function evaluateWebView(webview:WebView, script:String):Future<Result<String, NativeKitError>> {
		ensureLive();
		if (webview == null || script == null) throw BindingError.invalidArgument("Requests.evaluateWebView",
			"WebView and script cannot be null");
		return registerRequest(NativeKit.nk_webview_eval_checked(webview.nativeHandle(), script),
			(value, _) -> switch value {
				case Answered(WebViewEvaluation(_, json)): settled(json);
				case _: wrongEvent("WebView evaluation");
			});
	}

	/**
	 * Explicit interop for a native request, whose `decode` gives its outcome. A decoder that throws has a bug: the future
	 * settles as `Stopped` and the exception reaches the event pump.
	 */
	public function trackNative<T>(request:haxe.Int64, decode:PlatformEvent->Outcome<T>,
			?cancelNative:Void->Void):Future<T> {
		ensureLive();
		if (decode == null) throw BindingError.invalidArgument("Requests.trackNative", "Decoder cannot be null");
		return registerRequest(request, (value, _) -> switch value {
			case Happened(event): decode(event);
			case _: wrongEvent("native request");
		}, cancelNative);
	}

	/** Observes a native task without installing a managed worker callback. The caller owns the task. */
	public function trackTask<T>(task:Task, decode:haxe.io.Bytes->T):Future<Result<T, NativeKitError>> {
		ensureLive();
		if (task == null || decode == null) throw BindingError.invalidArgument("Requests.trackTask",
			"Task and decoder cannot be null");
		return register("task:" + Std.string(task.nativeHandle().rawValue), (value, _) -> switch value {
			// register() catches decoder exceptions separately from completion-observer exceptions.
			case Answered(TaskComplete(_, data)): Success(Ok(decode(data)));
			case Answered(TaskFailed(_, error, _)): settled(Err(error));
			case Answered(TaskCancelled(_)): Outcome.Cancelled;
			case _: wrongEvent("task");
		}, task.cancel);
	}

	function resourceDialog(request:haxe.Int64):Future<Result<Array<Resource>, NativeKitError>> {
		return registerRequest(request, (value, _) -> switch value {
			case Answered(DialogResources(_, items)): settled(items);
			case _: wrongEvent("resource dialog");
		}, () -> NativeKit.nk_dialog_cancel_checked(request));
	}

	function registerRequest<T>(request:haxe.Int64, decode:Delivery->Bool->Outcome<T>,
			?cancelNative:Void->Void):Future<T> {
		if (request == haxe.Int64.ofInt(0)) throw BindingError.invalidArgument("Requests.registerRequest",
			"Request ID cannot be zero");
		return register("request:" + Std.string(request), decode, cancelNative);
	}

	function register<T>(key:String, decode:Delivery->Bool->Outcome<T>,
			cancelNative:Null<Void->Void>):Future<T> {
		ensureLive();
		if (entries.exists(key)) throw BindingError.invalidState("Requests.register", "Operation is already tracked");
		var promise = new Promise<T>();
		var entry = new NativeRequestEntry(value -> {
			// A decoder that throws has a bug, which the event pump reports; the future's observers learn it ended.
			var outcome:Outcome<T>;
			try {
				outcome = decode(value, promise.future.isCancellationRequested());
				if (outcome == null)
					throw BindingError.invalidData("Requests.decode", "Decoder did not return an outcome");
			} catch (error:Dynamic) {
				promise.resolve(Stopped);
				throw error;
			}
			promise.resolve(outcome);
		}, promise.cancel);
		entries.set(key, entry);
		promise.setControls(cancelNative, () -> {
			if (entries.get(key) == entry) entries.remove(key);
		});
		return promise.future;
	}

	/**
	 * Settles the request `completion` answers, detaching its entry before invoking observers so tracking again from
	 * one is safe. Returns false when no request awaits it.
	 */
	@:allow(haxeon.platform.event.EventPump)
	internal function complete(completion:Completion):Bool {
		ensureLive();
		var key = completionKey(completion);
		var entry = entries.get(key);
		if (entry == null) return false;
		switch completion {
			case TaskProgress(_, _): return true;
			case _:
		}
		entries.remove(key);
		entry.receive(Answered(completion));
		return true;
	}

	/** Settles the request a native event answers that only `trackNative` follows. */
	public function handle(value:PlatformEvent):Bool {
		ensureLive();
		var key = eventKey(value);
		if (key == null) return false;
		var entry = entries.get(key);
		if (entry == null) return false;
		entries.remove(key);
		entry.receive(Happened(value));
		return true;
	}

	@:allow(haxeon.platform.event.EventPump)
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

	/** How many requests have not completed. */
	public function pending():Int {
		var count = 0;
		for (_ in entries) count++;
		return count;
	}

	function ensureLive():Void {
		if (disposed) throw BindingError.disposed("Requests", "Requests have been disposed with their runtime");
	}

	static function completionKey(completion:Completion):String
		return switch completion {
			case TaskProgress(task, _) | TaskComplete(task, _) | TaskFailed(task, _, _) | TaskCancelled(task):
				"task:" + Std.string(task.rawValue);
			case ClipboardText(id, _) | ClipboardFiles(id, _) | ClipboardResources(id, _) | DialogResources(id, _)
				| DialogMessage(id, _) | WebViewEvaluation(id, _) | ResourceCommit(id, _) | ResourceData(id, _):
				"request:" + Std.string(id);
		};

	static function eventKey(value:PlatformEvent):Null<String> {
		var key:Null<String> = switch value {
			case WebViewNavigationRequest(_, id, _): Std.string(id);
			case ResourceAssetReady(_, id): Std.string(id);
			case ResourceAssetLoadFailed(_, id, _): Std.string(id);
			// An answer with no typed case.
			case Raw(_, _, id, _, _, _, _): Std.string(id);
			case _: null;
		};
		return key == null || key == "0" ? null : "request:" + key;
	}

	/** A request's answer as its future's outcome: `Cancelled` when it was cancelled or the user dismissed it. */
	static function settled<T>(answer:Result<T, NativeKitError>):Outcome<Result<T, NativeKitError>>
		return switch answer {
			case Err(NativeKitError.Cancelled): Outcome.Cancelled;
			case _: Success(answer);
		};

	@:noReturn
	static function wrongEvent<T>(name:String):Outcome<T>
		throw BindingError.invalidData("Requests.decode", 'NativeKit $name completed with the wrong event');
}

/** The registry owns one delivery path and one shutdown path per operation. */
private class NativeRequestEntry {
	public final receive:Delivery->Void;
	public final shutdown:Void->Void;

	public function new(receive:Delivery->Void, shutdown:Void->Void) {
		this.receive = receive;
		this.shutdown = shutdown;
	}
}
