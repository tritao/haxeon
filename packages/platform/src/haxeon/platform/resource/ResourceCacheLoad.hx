package haxeon.platform.resource;

/** Result of joining or starting an asynchronous resource cache load. */
class ResourceCacheLoad {
	public final asset:ResourceAsset;
	public final request:haxe.Int64;

	@:allow(haxeon.platform.resource.ResourceCache)
	private function new(asset:ResourceAsset, request:haxe.Int64) {
		this.asset = asset;
		this.request = request;
	}
}
