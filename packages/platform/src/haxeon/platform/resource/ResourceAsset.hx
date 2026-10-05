package haxeon.platform.resource;

import nativekit.ffi.NativeKit;
import nativekit.ffi.NativeKitTypes;
import haxeon.platform.NativeKitError;
import haxe.io.Bytes;

/** One independently owned view of complete bytes retained by a resource cache. */
class ResourceAsset {
	final value:ResourceAssetHandle;
	final owned:OwnedResourceAssetHandle;
	var disposed:Bool = false;

	@:allow(haxeon.platform.resource.ResourceCache)
	private function new(owned:OwnedResourceAssetHandle) {
		this.owned = owned;
		this.value = owned.borrow();
	}

	public function nativeHandle():ResourceAssetHandle {
		ensureLive();
		return value;
	}

	/** Returns the URI used as this asset's cache identity. */
	public function uri():String {
		ensureLive();
		var buffer = NativeKit.nk_resource_asset_get_uri_checked(value);
		if (buffer == null)
			throw "NativeKit resource asset returned no URI";
		return buffer.sub(0, buffer.length - 1).toString();
	}

	/** Returns the current loading state. */
	public function loadState():ResourceAssetLoadState {
		ensureLive();
		return NativeKit.nk_resource_asset_get_load_state_checked(value);
	}

	/** Returns the underlying load result without throwing for a failed asset. */
	public function loadResult():Result {
		ensureLive();
		return NativeKit.nk_resource_asset_get_result_checked(value);
	}

	/** Returns the complete byte count once the asset is ready. */
	public function size():haxe.Int64 {
		ensureLive();
		return NativeKit.nk_resource_asset_get_size_checked(value);
	}

	/** Returns a copy of the complete bytes; fails while loading or after a load failure. */
	public function copyData():Bytes {
		ensureLive();
		var byteCount = size();
		if (haxe.Int64.compare(byteCount, haxe.Int64.ofInt(0x7fffffff)) > 0)
			throw "NativeKit resource asset is too large for a Haxe byte buffer";
		var bytes = Bytes.alloc(haxe.Int64.toInt(byteCount));
		NativeKit.nk_resource_asset_copy_data_checked(value, bytes, byteCount);
		return bytes;
	}

	/** Releases this asset view; the cache entry remains independently retained. */
	public function dispose():Void {
		if (disposed)
			return;
		var status = owned.close();
		disposed = true;
		if (status != null && status != Result.Ok)
			throw new haxeon.platform.NativeKitError(status, "resource.asset.dispose", NativeKit.nk_last_error());
	}

	public function isDisposed():Bool
		return disposed;

	function ensureLive():Void {
		if (disposed)
			throw "Resource asset has been disposed";
	}
}
