import haxeon.platform.NativeKitEvents;
import haxeon.platform.NativeKitRequests;
import haxeon.platform.NativeKitEventValue;
import haxeon.platform.NativeKitRequestOutcome;
import haxeon.platform.NativeTask;
import haxeon.platform.NativePromise;
import haxeon.platform.NativeResourceRegistry;
import haxeon.platform.RuntimeOptions;
import haxeon.platform.WindowConfig;
import haxeon.platform.SurfaceConfig;
import haxeon.platform.WebViewConfig;
import haxeon.platform.FileDialogConfig;
import haxeon.platform.FileDialogFilter;
import haxeon.platform.MessageDialogConfig;
import nativekit.ffi.NativeKitTypes;

/** Synthetic task events test routing without installing a managed worker callback. */
class NativeKitLifetimeTests {
	static var shutdownCompleted:Bool = false;
	static var secondShutdownCompleted:Bool = false;

	public static function run(events:NativeKitEvents):Bool {
		var requests = events.requests;
		var source = new Handle(900001);
		var task = NativeTask.adopt(new TaskHandle(source.rawValue()));
		var value = 0;
		var future = requests.trackTask(task, function(bytes) return bytes.length);
		future.onComplete(function(outcome) switch outcome {
			case Success(length): value = length;
			case _: value = -1;
		});
		var progress = requests.handle(TaskProgress(source, haxe.io.Bytes.alloc(0)));
		if (!progress || future.isComplete() || requests.pending() != 1) return false;
		if (!requests.handle(TaskComplete(source, Result.Ok, haxe.io.Bytes.alloc(7)))) return false;
		if (value != 7 || !future.isComplete() || requests.pending() != 0) return false;
		if (requests.handle(TaskComplete(source, Result.Ok, haxe.io.Bytes.alloc(7)))) return false;

		var decodingFailed = false;
		var bad = requests.trackTask(task, function(bytes):Int { throw "bad payload"; });
		bad.onComplete(function(outcome) switch outcome {
			case Failure(result, message): decodingFailed = result == Result.ErrorUnknown && message == "bad payload";
			case _:
		});
		requests.handle(TaskComplete(source, Result.Ok, haxe.io.Bytes.alloc(0)));
		if (!decodingFailed || !bad.isComplete() || requests.pending() != 0) return false;

		var cancelled = false;
		var cancelling = requests.trackTask(task, function(bytes) return bytes.length);
		cancelling.onComplete(function(outcome) switch outcome { case Cancelled: cancelled = true; case _: });
		requests.handle(TaskCancelled(source, Result.ErrorCancelled, haxe.io.Bytes.alloc(0)));
		if (!cancelled || !cancelling.isComplete() || requests.pending() != 0) return false;

		// A failed native cancellation must propagate and leave completion retryable.
		var cancellationFailed = false;
		var retry = requests.trackTask(task, function(bytes) return bytes.length);
		try retry.cancel() catch (_:Dynamic) cancellationFailed = true;
		if (!cancellationFailed || retry.isComplete()) return false;
		requests.handle(TaskComplete(source, Result.Ok, haxe.io.Bytes.alloc(1)));
		if (!retry.isComplete()) return false;

		// One throwing observer must not starve other completion observers.
		var promise = new NativePromise<Int>();
		var observed = false;
		promise.future.onComplete(function(_) { throw "observer failed"; });
		promise.future.onComplete(function(_) { observed = true; });
		var observerFailed = false;
		try promise.complete(1) catch (_:Dynamic) observerFailed = true;
		if (!observed || !observerFailed || !promise.future.isComplete()) return false;

		var registry = new NativeResourceRegistry();
		for (_ in 0...1000) registry.register(function() {}).detach();
		if (registry.count() != 0) return false;
		var order = "";
		registry.register(function() { order += "a"; });
		var shouldFail = true;
		registry.register(function() { if (shouldFail) throw "busy"; order += "b"; });
		var releaseFailed = false;
		try registry.releaseAll() catch (_:Dynamic) releaseFailed = true;
		if (!releaseFailed || order != "a" || registry.count() != 1) return false;
		shouldFail = false;
		registry.releaseAll();
		if (order != "ab" || registry.count() != 0) return false;

		// Managed descriptors own ABI initialization and retain managed values.
		var init = new RuntimeOptions();
		init.applicationName = "managed";
		if (init.nativeValue().get_struct_size() != InitOptions.size()) return false;
		var window = new WindowConfig(640, 480);
		window.title = "managed";
		if (window.nativeValue().get_width() != 640 || window.nativeValue().get_title() != "managed") return false;
		var surface = new SurfaceConfig(640, 480);
		if (surface.nativeValue().get_struct_size() != SurfaceOptions.size()) return false;
		var webview = new WebViewConfig(640, 480);
		webview.initialUrl = "about:blank";
		if (webview.nativeValue().get_initial_url() != "about:blank") return false;
		var dialog = new FileDialogConfig();
		dialog.filters = [new FileDialogFilter("Images", "*.png;*.jpg")];
		if (dialog.nativeValue().get_struct_size() != FileDialogOptions.size()) return false;
		if (new MessageDialogConfig("hello").nativeValue().get_message() != "hello") return false;

		// Retain a tracked future until runtime shutdown; it must settle and detach.
		var pending = requests.trackTask(task, function(bytes) return bytes.length);
		pending.onComplete(function(outcome) switch outcome {
			case Cancelled: shutdownCompleted = true; throw "shutdown observer";
			case _:
		});
		var secondTask = NativeTask.adopt(new TaskHandle(900002));
		requests.trackTask(secondTask, function(bytes) return bytes.length).onComplete(function(outcome) switch outcome {
			case Cancelled: secondShutdownCompleted = true;
			case _:
		});
		return true;
	}

	public static function afterShutdown(requests:NativeKitRequests):Bool {
		var rejected = false;
		try requests.track(haxe.Int64.ofInt(99), function(_) {}) catch (_:Dynamic) rejected = true;
		return shutdownCompleted && secondShutdownCompleted && requests.pending() == 0 && rejected;
	}
}
