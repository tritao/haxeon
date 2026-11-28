package haxeon.platform.event;

import haxeon.platform.NativeKitError;
import haxeon.platform.NativeKitStatus;
import haxeon.platform.async.Completion;
import nativekit.ffi.NativeKitTypes.EventKind;
import nativekit.ffi.NativeKitTypes.MessageResult;
import nativekit.ffi.NativeKitTypes.NativeKitTypesEnumDecoders;
import nativekit.ffi.NativeKitTypes.Result as NativeResult;

internal class ServiceEventDecoder {
	public static function decode(c:EventSnapshot):Null<Delivery> return switch c.kind {
		case EventKind.ClipboardTextComplete: Answered(ClipboardText(c.request, answer(c, c.data.toString())));
		case EventKind.ClipboardFilesComplete:
			Answered(ClipboardFiles(c.request, c.result == NativeResult.Ok
				? Ok(EventBytes.decodeClipboardFiles(c.data, c.dataCount)) : Err(failure(c, null))));
		case EventKind.DropFiles: Happened(DropFiles(c.source, EventBytes.decodeDropItems(c.data, c.dataCount)));
		case EventKind.DropText: Happened(DropText(c.source, EventBytes.decodeDropItems(c.data, c.dataCount).join("")));
		case EventKind.DialogMessageComplete:
			if (c.result != NativeResult.Ok)
				Answered(DialogMessage(c.request, Err(failure(c, null))));
			else {
				EventBytes.requireSize(c.data, c.data.length == 4 ? 4 : 8);
				var button = NativeKitTypesEnumDecoders.decodeMessageResult(EventBytes.readU32(c.data, 0));
				// No button is a dialog the user dismissed.
				Answered(DialogMessage(c.request, button == MessageResult.None ? Err(Cancelled) : Ok(button)));
			}
		case EventKind.WebviewNavigated: Happened(WebViewNavigated(c.source, c.data.toString()));
		case EventKind.WebviewMessage: Happened(WebViewMessage(c.source, c.data.toString()));
		case EventKind.WebviewTitleChanged: Happened(WebViewTitleChanged(c.source, c.data.toString()));
		// A failed evaluation's payload is the script's error message.
		case EventKind.WebviewEvalComplete:
			Answered(WebViewEvaluation(c.request, c.result == NativeResult.Ok ? Ok(c.data.toString())
				: Err(failure(c, c.data.toString()))));
		case EventKind.WebviewNavigationFailed: Happened(WebViewNavigationFailed(c.source,
			NativeKitTypesEnumDecoders.decodeNavigationError(c.flags), c.data.toString()));
		case EventKind.WebviewNavigationRequest: Happened(WebViewNavigationRequest(c.source, c.request,
			c.data.toString()));
		case EventKind.NotificationActivated: Happened(NotificationActivated(c.request, c.data.toString()));
		case EventKind.NotificationFailed: Happened(NotificationFailed(c.request, c.data.toString()));
		case EventKind.TaskProgress: Answered(TaskProgress(c.source, c.data));
		case EventKind.TaskComplete: Answered(TaskComplete(c.source, c.data));
		case EventKind.TaskFailed: Answered(TaskFailed(c.source, failure(c, null), c.data));
		case EventKind.TaskCancelled: Answered(TaskCancelled(c.source));
		default: null;
	}

	/** `value` when the event succeeded, else why it failed. */
	static function answer<T>(c:EventSnapshot, value:T):Result<T, NativeKitError>
		return c.result == NativeResult.Ok ? Ok(value) : Err(failure(c, null));

	static function failure(c:EventSnapshot, diagnostic:Null<String>):NativeKitError
		return NativeKitStatus.reported(c.result, diagnostic);
}
