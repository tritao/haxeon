package haxeon.platform.resource;

import haxeon.platform.BindingError;
import haxeon.platform.NativeKitStatus;
import nativekit.ffi.NativeKit;
import nativekit.ffi.NativeKitTypes.ResourceFlags;
import nativekit.ffi.NativeKitTypes.ResourceValue;
import nativekit.ffi.NativeKitTypes.Result;

/** Describes a URI-backed NativeKit resource for NativeKit APIs. */
class Resource {
	/** What may be done with it, such as reading or writing. */
	public final flags:ResourceFlags;

	/** Where it is. */
	public final uri:String;

	/** Its media type, or null. */
	public final mimeType:Null<String>;

	/** A name to show for it, or null. */
	public final displayName:Null<String>;

	/** A resource at `uri`, readable unless `flags` say otherwise. */
	public function new(uri:String, ?mimeType:String, ?displayName:String,
			?flags:ResourceFlags) {
		if (uri == null || uri.length == 0)
			throw BindingError.invalidArgument("Resource.new", "NativeKit resource URI must not be empty");
		this.flags = flags == null ? ResourceFlags.Readable : flags;
		this.uri = uri;
		this.mimeType = mimeType;
		this.displayName = displayName;
	}

	/** Returns the ABI value for a synchronous NativeKit call. */
	public function nativeValue():ResourceValue {
		var value = new ResourceValue();
		value.struct_size = ResourceValue.byteSize();
		value.flags = flags;
		value.uri = uri;
		value.mime_type = mimeType;
		value.display_name = displayName;
		return value;
	}

	/** Cancels a pending generic asynchronous resource load. */
	public static function cancelLoad(request:haxe.Int64):Void {
		var status = NativeKit.nk_resource_load_cancel(request);
		if (status != Result.Ok)
			throw NativeKitStatus.failure(status, "resource.cancelLoad", NativeKit.nk_last_error());
	}
}
