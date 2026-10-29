package haxeon.platform.internal.event;

import haxeon.platform.event.PlatformEvent;
import haxeon.platform.internal.event.EventBytes;
import haxeon.platform.internal.event.EventSnapshot;
import nativekit.ffi.NativeKitTypes.ClipboardFiles;
import nativekit.ffi.NativeKitTypes.EventKind;

class ServiceEventDecoder {
	public static function decode(c:EventSnapshot):Null<PlatformEvent> return switch c.kind {
		case EventKind.None: None;
		case EventKind.ClipboardTextComplete: ClipboardText(c.request,c.result,c.data.toString());
		case EventKind.ClipboardFilesComplete: ClipboardFiles(c.request,c.result,EventBytes.decodeClipboardFiles(c.data,c.dataCount));
		case EventKind.DropFiles: DropFiles(c.source,EventBytes.decodeDropItems(c.data,c.dataCount));
		case EventKind.DropText: DropText(c.source,EventBytes.decodeDropItems(c.data,c.dataCount).join(""));
		case EventKind.DialogMessageComplete:
			EventBytes.requireSize(c.data,c.data.length == 4 ? 4 : 8); DialogMessage(c.request,c.result,EventBytes.readU32(c.data,0),
				c.data.length >= 8 && EventBytes.readU32(c.data,4) != 0);
		case EventKind.WebviewNavigated: WebViewNavigated(c.source,c.data.toString());
		case EventKind.WebviewMessage: WebViewMessage(c.source,c.data.toString());
		case EventKind.WebviewTitleChanged: WebViewTitleChanged(c.source,c.data.toString());
		case EventKind.WebviewEvalComplete: WebViewEvaluation(c.source,c.request,c.result,c.data.toString());
		case EventKind.WebviewNavigationFailed: WebViewNavigationFailed(c.source,c.flags,c.data.toString());
		case EventKind.WebviewNavigationRequest: WebViewNavigationRequest(c.source,c.request,c.data.toString());
		case EventKind.NotificationActivated: NotificationActivated(c.request,c.data.toString());
		case EventKind.NotificationFailed: NotificationFailed(c.request,c.data.toString());
		case EventKind.TaskProgress: TaskProgress(c.source,c.data);
		case EventKind.TaskComplete: TaskComplete(c.source,c.result,c.data);
		case EventKind.TaskFailed: TaskFailed(c.source,c.result,c.data);
		case EventKind.TaskCancelled: TaskCancelled(c.source,c.result,c.data);
		default:null;
	}
}
