package haxeon.audio;

import nativekit.ffi.NativeKit;
import nativekit.ffi.NativeKitTypes;
import haxeon.platform.resource.Resource;
import haxeon.platform.resource.ResourceAsset;

/**
 * One named resource in an AudioBank.
 *
 * The entry owns its ResourceAsset view. Clips created from it are independent
 * caller-owned audio resources and remain valid after the entry is unloaded.
 */
class AudioBankEntry {
	public final name:String;
	public final resource:Resource;
	final asset:ResourceAsset;
	public final request:haxe.Int64;
	var readyNotified:Bool = false;
	var failedNotified:Bool = false;
	var disposed:Bool = false;

	@:allow(haxeon.audio.AudioBank)
	private function new(name:String, resource:Resource, asset:ResourceAsset, request:haxe.Int64) {
		this.name = name;
		this.resource = resource;
		this.asset = asset;
		this.request = request;
	}

	/** Returns the underlying cache asset loading state. */
	public function loadState():ResourceAssetLoadState {
		ensureLive();
		return asset.loadState();
	}

	/** Returns the cache result without throwing for a failed load. */
	public function loadResult():Result {
		ensureLive();
		return asset.loadResult();
	}

	public function isLoading():Bool
		return loadState() == ResourceAssetLoadState.Loading;

	public function isReady():Bool
		return loadState() == ResourceAssetLoadState.Ready;

	public function isFailed():Bool
		return loadState() == ResourceAssetLoadState.LoadFailed;

	/** Creates a caller-owned clip from the ready cached bytes. */
	public function createClip():Clip {
		ensureLive();
		if (!isReady())
			throw "Audio bank entry is not ready: " + name;
		return Clip.fromAsset(asset);
	}

	public function isDisposed():Bool
		return disposed;

	@:allow(haxeon.audio.AudioBank)
	private function markReadyNotified():Bool {
		if (readyNotified)
			return false;
		readyNotified = true;
		return true;
	}

	@:allow(haxeon.audio.AudioBank)
	private function markFailedNotified():Bool {
		if (failedNotified)
			return false;
		failedNotified = true;
		return true;
	}

	@:allow(haxeon.audio.AudioBank)
	private function matches(source:Handle, eventRequest:haxe.Int64):Bool {
		return !disposed && !asset.isDisposed() &&
			asset.nativeHandle().rawValue() == source.rawValue() &&
			haxe.Int64.compare(request, eventRequest) == 0;
	}

	@:allow(haxeon.audio.AudioBank)
	private function dispose():Void {
		if (disposed)
			return;
		asset.dispose();
		disposed = true;
	}

	function ensureLive():Void {
		if (disposed)
			throw "Audio bank entry has been unloaded: " + name;
	}
}
