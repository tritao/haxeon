package haxeon.platform.event;

import haxeon.platform.BindingError;
import haxeon.platform.NativeKitError;
import haxeon.platform.NativeKitStatus;
import haxeon.platform.resource.Resource;
import nativekit.ffi.NativeKitTypes.EventKind;
import nativekit.ffi.NativeKitTypes.ResourceDrop;
import nativekit.ffi.NativeKitTypes.Result as NativeResult;

internal class ResourceEventDecoder {
	public static function decode(c:EventSnapshot):Null<Delivery> return switch c.kind {
		case EventKind.DialogResourcesComplete: Answered(DialogResources(c.request, chosen(c, true)));
		case EventKind.ClipboardResourcesComplete: Answered(ClipboardResources(c.request, chosen(c, false)));
		case EventKind.ResourceOpened: Happened(ResourcesOpened(EventBytes.decodeResourceList(c.data, 0).items));
		case EventKind.ShareReceived:
			var o = EventBytes.readU32(c.data, 0), d = EventBytes.decodeResourceList(c.data, o);
			Happened(ShareReceived(EventBytes.readOptionalString(c.data, EventBytes.readU32(c.data, 4), 16),
				EventBytes.readOptionalString(c.data, EventBytes.readU32(c.data, 8), 16), d.items));
		case EventKind.ResourceDrop:
			if (c.data.length < 32) throw BindingError.invalidData("ResourceEventDecoder.decode",
				"NativeKit resource drop payload is truncated");
			var h:ResourceDrop = c.data, d = EventBytes.decodeResourceList(c.data, h.get_resources_offset());
			Happened(ResourceDrop(c.source, h.get_x(), h.get_y(),
				EventBytes.readOptionalString(c.data, h.get_text_offset(), 32), d.items));
		case EventKind.ResourceCommitComplete:
			Answered(ResourceCommit(c.request, c.result == NativeResult.Ok ? Ok((c.flags & 1) != 0)
				: Err(NativeKitStatus.reported(c.result, null))));
		case EventKind.ResourceCacheReady: Happened(ResourceAssetReady(c.source, c.request));
		case EventKind.ResourceCacheLoadFailed: Happened(ResourceAssetLoadFailed(c.source, c.request, c.result));
		default: null;
	}

	/** The resources a dialog or the clipboard gave, or why not: a `dialog` the user dismissed is `Cancelled`. */
	static function chosen(c:EventSnapshot, dialog:Bool):Result<Array<Resource>, NativeKitError> {
		if (c.result != NativeResult.Ok)
			return Err(NativeKitStatus.reported(c.result, null));
		var list = EventBytes.decodeResourceList(c.data, 0);
		return list.accepted || !dialog ? Ok(list.items) : Err(Cancelled);
	}
}
