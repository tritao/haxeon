package haxeon.audio;

import haxeon.platform.BindingError;

import haxeon.platform.resource.Resource;
import haxeon.platform.resource.ResourceAsset;
import nativekit.ffi.NativeKit;
import nativekit.ffi.NativeKitTypes;

/**
 * One named resource in an AudioBank.
 *
 * The entry owns its ResourceAsset view. Clips created from it are independent
 * caller-owned audio resources and remain valid after the entry is unloaded.
 */
class AudioBankEntry {
	/** The entry's name in its bank. */
	public final name:String;

	/** The resource it loads. */
	public final resource:Resource;
	final asset:ResourceAsset;

	/** The cache request loading it, which resource events name. */
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

	/** Whether it is still loading. */
	public function isLoading():Bool
		return loadState() == ResourceAssetLoadState.Loading;

	/** Whether it has loaded. */
	public function isReady():Bool
		return loadState() == ResourceAssetLoadState.Ready;

	/** Whether loading failed. */
	public function isFailed():Bool
		return loadState() == ResourceAssetLoadState.LoadFailed;

	/** Creates a caller-owned clip from the ready cached bytes. */
	public function createClip():Clip {
		ensureLive();
		if (!isReady())
			throw BindingError.invalidArgument("AudioBankEntry.createClip", "Audio bank entry is not ready: " + name);
		return Clip.fromAsset(asset);
	}

	/** Whether it has been disposed. */
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
		return !disposed && !asset.isDisposed() && asset.nativeHandle().rawValue == source.rawValue
			&& haxe.Int64.compare(request, eventRequest) == 0;
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
			throw BindingError.invalidArgument("AudioBankEntry.ensureLive",
				"Audio bank entry has been unloaded: " + name);
	}
}
