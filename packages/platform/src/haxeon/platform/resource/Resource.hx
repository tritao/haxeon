package haxeon.platform.resource;

import nativekit.ffi.NativeKit;
import nativekit.ffi.NativeKitTypes;
import haxeon.platform.NativeKitError;

/** Describes a URI-backed NativeKit resource for NativeKit APIs. */
class Resource {
	public final flags:ResourceFlags;
	public final uri:String;
	public final mimeType:Null<String>;
	public final displayName:Null<String>;

	public function new(uri:String, ?mimeType:String, ?displayName:String,
		?flags:ResourceFlags) {
		if (uri == null || uri.length == 0)
			throw "NativeKit resource URI must not be empty";
		this.flags = flags == null ? ResourceFlags.Readable : flags;
		this.uri = uri;
		this.mimeType = mimeType;
		this.displayName = displayName;
	}

	/** Returns the ABI value for a synchronous NativeKit call. */
	public function nativeValue():ResourceValue {
		var value = new ResourceValue();
		value.set_struct_size(ResourceValue.size());
		value.set_flags(flags);
		value.set_uri(uri);
		value.set_mime_type(mimeType);
		value.set_display_name(displayName);
		return value;
	}

	/** Cancels a pending generic asynchronous resource load. */
	public static function cancelLoad(request:haxe.Int64):Void {
		var status = NativeKit.nk_resource_load_cancel(request);
		if (status != Result.Ok)
			throw new haxeon.platform.NativeKitError(status, "resource.cancelLoad", NativeKit.nk_last_error());
	}
}
