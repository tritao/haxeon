package haxeon.ui.core;

import haxeon.async.Future;
import haxeon.platform.NativeKitError;
import haxeon.platform.async.Requests;
import nativekit.ffi.NativeKit;

/**
 * The clipboard text fields copy to and paste from. Reads go through the platform's requests, which a host attaches
 * with its surface (`UiSurfaceBinding`); without them, as in a headless test, a read answers `Unsupported`.
 */
class ClipboardService implements Disposable {
	final reads:Array<Future<Result<String, NativeKitError>>> = [];
	var requests:Null<Requests> = null;
	var disposed = false;

	/** The clipboard bridge; `UiContext` makes the one its widgets share. */
	public function new() {}

	/** Reads through `requests` from now on. */
	public function attach(requests:Requests):Void {
		ensureLive();
		this.requests = requests;
	}

	/** Stops reading through the attached requests; a read still in flight answers nothing, its reader having gone. */
	public function detach():Void {
		requests = null;
		stopReads();
	}

	/** Copies UTF-8 text to the system clipboard. */
	public function writeText(text:String):Void {
		ensureLive();
		NativeKit.nk_clipboard_set_text_checked(text == null ? "" : text);
	}

	/**
	 * Reads the clipboard's text and answers `handler` with it, or with why not: `Unsupported` without a host,
	 * `Cancelled` when the read was, or what the platform reported.
	 */
	public function readText(handler:Result<String, NativeKitError>->Void):Void {
		ensureLive();
		if (handler == null)
			throw "Clipboard reads require a completion handler";
		var source = requests;
		if (source == null) {
			handler(Err(Unsupported("no platform clipboard is attached")));
			return;
		}
		var read = source.readClipboardText();
		reads.push(read);
		read.onComplete(function(outcome) {
			reads.remove(read);
			switch outcome {
				case Success(answer): handler(answer);
				case Cancelled: handler(Err(Cancelled));
				case Stopped:
			}
		});
	}

	public function dispose():Void {
		if (disposed)
			return;
		stopReads();
		requests = null;
		disposed = true;
	}

	function stopReads():Void {
		for (read in reads.copy())
			read.stopObserving();
		reads.resize(0);
	}

	function ensureLive():Void {
		if (disposed)
			throw "Clipboard service has been disposed";
	}
}
