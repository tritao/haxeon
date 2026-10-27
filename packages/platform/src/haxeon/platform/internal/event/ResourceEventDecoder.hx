package haxeon.platform.internal.event;

import haxeon.platform.BindingError;
import haxeon.platform.event.PlatformEvent;
import haxeon.platform.internal.event.EventBytes;
import haxeon.platform.internal.event.EventSnapshot;
import nativekit.ffi.NativeKitTypes.EventKind;
import nativekit.ffi.NativeKitTypes.ResourceDrop;

class ResourceEventDecoder {
	public static function decode(c:EventSnapshot):Null<PlatformEvent> return switch c.kind {
		case EventKind.DialogResourcesComplete:
			var d=EventBytes.decodeResourceList(c.data,0); Resources(c.kind,c.request,c.result,d.accepted,d.items);
		case EventKind.ClipboardResourcesComplete | EventKind.ResourceOpened:
			var d=EventBytes.decodeResourceList(c.data,0); Resources(c.kind,c.request,c.result,d.accepted,d.items);
		case EventKind.ShareReceived:
			var o=EventBytes.readU32(c.data,0),d=EventBytes.decodeResourceList(c.data,o);
			ShareReceived(EventBytes.readOptionalString(c.data,EventBytes.readU32(c.data,4),16),EventBytes.readOptionalString(c.data,EventBytes.readU32(c.data,8),16),d.items);
		case EventKind.ResourceDrop:
			if(c.data.length<32) throw BindingError.invalidData("ResourceEventDecoder.decode", "NativeKit resource drop payload is truncated");
			var h:ResourceDrop=c.data,d=EventBytes.decodeResourceList(c.data,h.get_resources_offset());
			ResourceDrop(c.source,h.get_x(),h.get_y(),EventBytes.readOptionalString(c.data,h.get_text_offset(),32),d.items);
		case EventKind.ResourceCommitComplete:
			ResourceCommit(c.request, c.result, (c.flags & 1) != 0);
		case EventKind.ResourceCacheReady: ResourceAssetReady(c.source, c.request);
		case EventKind.ResourceCacheLoadFailed: ResourceAssetLoadFailed(c.source, c.request, c.result);
		default:null;
	}
}
