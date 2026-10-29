package haxeon.platform.resource;

import haxeon.platform.BindingError;
import haxeon.platform.NativeKitError;
import haxeon.platform.resource.ResourceCacheLoad;
import nativekit.ffi.NativeKit;
import nativekit.ffi.NativeKitTypes.OwnedResourceCacheHandle;
import nativekit.ffi.NativeKitTypes.ResourceCacheHandle;
import nativekit.ffi.NativeKitTypes.Result;

/** Native URI cache for deduplicated, complete resource byte loads. */
class ResourceCache {
	final value:ResourceCacheHandle;
	final owned:OwnedResourceCacheHandle;
	var disposed:Bool = false;

	private function new(owned:OwnedResourceCacheHandle) {
		this.owned = owned;
		this.value = owned.borrow();
	}

	public static function create():ResourceCache {
		return new ResourceCache(NativeKit.nk_resource_cache_create_checked());
	}

	public function load(resource:Resource):ResourceAsset {
		ensureLive();
		if (resource == null)
			throw BindingError.invalidArgument("ResourceCache.load", "Resource cache resource must not be null");
		var owned = NativeKit.nk_resource_cache_load_checked(value, resource.nativeValue());
		return new ResourceAsset(owned);
	}

	public function loadAsync(resource:Resource):ResourceCacheLoad {
		ensureLive();
		if (resource == null)
			throw BindingError.invalidArgument("ResourceCache.loadAsync", "Resource cache resource must not be null");
		var result = NativeKit.nk_resource_cache_load_async_checked(value, resource.nativeValue());
		return new ResourceCacheLoad(new ResourceAsset(result.out_asset), result.out_request);
	}

	public function find(uri:String):ResourceAsset {
		ensureLive();
		if (uri == null || uri.length == 0)
			throw BindingError.invalidArgument("ResourceCache.find", "Resource cache URI must not be empty");
		var owned = NativeKit.nk_resource_cache_find_checked(value, uri);
		return new ResourceAsset(owned);
	}

	public function remove(uri:String):Void {
		ensureLive();
		if (uri == null || uri.length == 0)
			throw BindingError.invalidArgument("ResourceCache.remove", "Resource cache URI must not be empty");
		NativeKit.nk_resource_cache_remove_checked(value, uri);
	}

	public function clear():Void {
		ensureLive();
		NativeKit.nk_resource_cache_clear_checked(value);
	}

	public function count():Int {
		ensureLive();
		return NativeKit.nk_resource_cache_get_count_checked(value);
	}

	public function dispose():Void {
		if (disposed)
			return;
		var status = owned.close();
		disposed = true;
		if (status != null && status != Result.Ok)
			throw new NativeKitError(status, "resource.cache.dispose", NativeKit.nk_last_error());
	}

	public function isDisposed():Bool
		return disposed;

	function ensureLive():Void {
		if (disposed)
			throw BindingError.disposed("ResourceCache.ensureLive", "Resource cache has been disposed");
	}
}
