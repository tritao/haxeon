import haxeon.async.Outcome;
import haxeon.async.Promise;
import haxeon.platform.DisposalRegistry;
import haxeon.platform.RuntimeOptions;
import haxeon.platform.SurfaceOptions;
import haxeon.platform.WebViewOptions;
import haxeon.platform.WindowOptions;
import haxeon.platform.async.Completion;
import haxeon.platform.async.Requests;
import haxeon.platform.async.Task;
import haxeon.platform.dialog.FileDialogFilter;
import haxeon.platform.dialog.FileDialogOptions;
import haxeon.platform.dialog.MessageDialogOptions;
import haxeon.platform.event.EventPump;
import haxeon.platform.event.PlatformEvent;
import nativekit.ffi.NativeKitTypes;
import nativekit.ffi.NativeKitTypes.FileDialogOptions as NativeFileDialogOptions;
import nativekit.ffi.NativeKitTypes.SurfaceOptions as NativeSurfaceOptions;

/** Synthetic task events test routing without installing a managed worker callback. */
class NativeKitLifetimeTests {
	/** A completion with no typed case, as `trackNative` follows, carrying `text`. */
	static function rawAnswer(id:haxe.Int64, text:String):PlatformEvent
		return Raw(EventKind.PluginEvent, new Handle(0), id, Result.Ok, 0, 0, haxe.io.Bytes.ofString(text));

	static var shutdownCompleted:Bool = false;
	static var secondShutdownCompleted:Bool = false;

	public static function run(events:EventPump):Bool {
		if (!BindingErrorTests.run()) return false;
		var requests = events.requests;
		var source = new Handle(900001);
		var task = Task.adopt(new TaskHandle(source.rawValue));
		var value = 0;
		var future = requests.trackTask(task, bytes -> bytes.length);
		future.onComplete(outcome -> switch outcome {
			case Success(Ok(length)): value = length;
			case _: value = -1;
		});
		var progress = requests.complete(TaskProgress(source, haxe.io.Bytes.alloc(0)));
		if (!progress || future.isComplete() || requests.pending() != 1) return false;
		if (!requests.complete(TaskComplete(source, haxe.io.Bytes.alloc(7)))) return false;
		if (value != 7 || !future.isComplete() || requests.pending() != 0) return false;
		if (requests.complete(TaskComplete(source, haxe.io.Bytes.alloc(7)))) return false;

		// A decoder that throws has a bug: the future stops, and the exception reaches the event pump.
		var decodingFailed = false, badStopped = false;
		var bad = requests.trackTask(task, function(bytes):Int {
			throw new haxe.Exception("bad payload");
		});
		bad.onComplete(outcome -> switch outcome {
			case Stopped: badStopped = true;
			case _:
		});
		try requests.complete(TaskComplete(source, haxe.io.Bytes.alloc(0))) catch (error:haxe.Exception)
			decodingFailed = error.message == "bad payload";
		if (!decodingFailed || !badStopped || requests.pending() != 0) return false;

		var cancelled = false;
		var cancelling = requests.trackTask(task, bytes -> bytes.length);
		cancelling.onComplete(outcome -> switch outcome {
			case Cancelled: cancelled = true;
			case _:
		});
		requests.complete(TaskCancelled(source));
		if (!cancelled || !cancelling.isComplete() || requests.pending() != 0) return false;

		// A failed native cancellation must propagate and leave completion retryable.
		var cancellationFailed = false;
		var retry = requests.trackTask(task, bytes -> bytes.length);
		try retry.cancel() catch (_:Dynamic) cancellationFailed = true;
		if (!cancellationFailed || retry.isComplete() || retry.isCancellationRequested()
			|| !retry.canCancel()) return false;
		requests.complete(TaskComplete(source, haxe.io.Bytes.alloc(1)));
		if (!retry.isComplete()) return false;

		// Stop observation is independent of native cancellation, including for tasks.
		var taskStopped = false;
		var stoppedTask = requests.trackTask(task, bytes -> bytes.length);
		stoppedTask.onComplete(outcome -> switch outcome {
			case Stopped: taskStopped = true;
			case _:
		});
		if (!stoppedTask.stopObserving() || !taskStopped || stoppedTask.isCancellationRequested()
			|| requests.pending() != 0) return false;
		if (requests.complete(TaskComplete(source, haxe.io.Bytes.alloc(1)))) return false;

		// Request IDs and task handles occupy different namespaces in the same registry.
		var id = haxe.Int64.ofInt(source.rawValue);
		var rawValue = 0;
		var raw = requests.trackNative(id, function(event):Outcome<Int> switch event {
			case Raw(_, _, _, _, _, _, data): Success(data.length);
			case _: Cancelled;
		});
		raw.onComplete(outcome -> switch outcome {
			case Success(n): rawValue = n;
			case _:
		});
		var duplicateRejected = false;
		try requests.trackNative(id,
			function(_):Outcome<Int> return Success(0)) catch (error:haxeon.platform.BindingError) {
			duplicateRejected = error.kind == haxeon.platform.BindingErrorKind.InvalidState;
		}
		var sameNumberTask = requests.trackTask(task, bytes -> bytes.length);
		if (!duplicateRejected || requests.pending() != 2) return false;
		requests.handle(rawAnswer(id, "abc"));
		if (rawValue != 3 || requests.pending() != 1 || sameNumberTask.isComplete()) return false;
		requests.complete(TaskComplete(source, haxe.io.Bytes.alloc(2)));
		if (!sameNumberTask.isComplete() || requests.pending() != 0) return false;

		// Native cancellation is idempotent, awaits acknowledgement, and tolerates a completion race.
		var calls = 0;
		var racing = requests.trackNative(id, function(_):Outcome<Int> return Success(9), () -> {
			calls++;
		});
		if (!racing.cancel() || racing.cancel() || calls != 1 || racing.isComplete()
			|| !racing.isCancellationRequested()) return false;
		requests.handle(rawAnswer(id, "done"));
		if (!racing.isComplete() || racing.cancel() || requests.pending() != 0) return false;

		// A decoder's exception reaches the event pump as it was thrown.
		var expectedError = haxeon.platform.BindingError.invalidData("test.decode", "bad format");
		var errorPreserved = false;
		var malformed = requests.trackNative(id, function(_):Outcome<Int> {
			throw expectedError;
		});
		try requests.handle(rawAnswer(id, "bad")) catch (error:haxeon.platform.BindingError)
			errorPreserved = error == expectedError;
		if (!errorPreserved || !malformed.isComplete() || requests.pending() != 0) return false;

		// Reusing a native ID while decoding must not let the old future detach its replacement.
		var previous:haxeon.async.Future<Int> = null;
		var replacement:haxeon.async.Future<Int> = null;
		previous = requests.trackNative(id, function(_):Outcome<Int> {
			replacement = requests.trackNative(id, function(_):Outcome<Int> return Success(2));
			previous.stopObserving();
			return Success(1);
		});
		requests.handle(rawAnswer(id, "first"));
		if (!previous.isComplete() || replacement.isComplete() || requests.pending() != 1) return false;
		requests.handle(rawAnswer(id, "second"));
		if (!replacement.isComplete() || requests.pending() != 0) return false;

		// One throwing observer must not starve other completion observers.
		var promise = new Promise<Int>();
		var observed = false;
		promise.future.onComplete(_ -> {
			throw "observer failed";
		});
		promise.future.onComplete(_ -> {
			observed = true;
		});
		var observerFailed = false;
		try promise.complete(1) catch (_:Dynamic) observerFailed = true;
		if (!observed || !observerFailed || !promise.future.isComplete()) return false;

		var registry = new DisposalRegistry();
		for (_ in 0...1000) registry.register(() -> {}).detach();
		if (registry.count() != 0) return false;
		var order = "";
		registry.register(() -> {
			order += "a";
		});
		var shouldFail = true;
		registry.register(() -> {
			if (shouldFail) throw "busy";
			order += "b";
		});
		var releaseFailed = false;
		try registry.releaseAll() catch (_:Dynamic) releaseFailed = true;
		if (!releaseFailed || order != "a" || registry.count() != 1) return false;
		shouldFail = false;
		registry.releaseAll();
		if (order != "ab" || registry.count() != 0) return false;

		// Managed descriptors own ABI initialization and retain managed values.
		var init = new RuntimeOptions();
		init.applicationName = "managed";
		if (init.nativeValue().get_struct_size() != InitOptions.byteSize()) return false;
		var window = new WindowOptions(640, 480);
		window.title = "managed";
		if (window.nativeValue().get_width() != 640 || window.nativeValue().get_title() != "managed") return false;
		var surface = new SurfaceOptions(640, 480);
		if (surface.nativeValue().get_struct_size() != NativeSurfaceOptions.byteSize()) return false;
		var webview = new WebViewOptions(640, 480);
		webview.initialUrl = "about:blank";
		if (webview.nativeValue().get_initial_url() != "about:blank") return false;
		var dialog = new FileDialogOptions();
		dialog.filters = [new FileDialogFilter("Images", "*.png;*.jpg")];
		if (dialog.nativeValue().get_struct_size() != NativeFileDialogOptions.byteSize()) return false;
		if (new MessageDialogOptions("hello").nativeValue().get_message() != "hello") return false;
		var asking = new MessageDialogOptions("Delete it?");
		asking.checkboxLabel = "Don't ask again";
		asking.yesLabel = "Delete";
		var asked = asking.nativeValue();
		if (asked.get_checkbox_label() != "Don't ask again" || asked.get_yes_label() != "Delete") return false;

		// Retain a tracked future until runtime shutdown; it must settle and detach.
		var pending = requests.trackTask(task, bytes -> bytes.length);
		pending.onComplete(outcome -> switch outcome {
			case Cancelled: shutdownCompleted = true;
				throw "shutdown observer";
			case _:
		});
		var secondTask = Task.adopt(new TaskHandle(900002));
		requests.trackTask(secondTask,
			bytes -> bytes.length).onComplete(outcome -> switch outcome {
				case Cancelled: secondShutdownCompleted = true;
				case _:
			});
		return true;
	}

	public static function afterShutdown(requests:Requests):Bool {
		var rejected = false;
		try requests.trackNative(haxe.Int64.ofInt(99), function(_):Outcome<Int> return Success(1))
		catch (error:haxeon.platform.BindingError) rejected = error.kind == haxeon.platform.BindingErrorKind.Disposed;
		return shutdownCompleted && secondShutdownCompleted && requests.pending() == 0 && rejected;
	}
}
