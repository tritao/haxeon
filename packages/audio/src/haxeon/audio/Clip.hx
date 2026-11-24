package haxeon.audio;

import haxeon.platform.BindingError;

import haxe.io.Bytes;
import haxeon.platform.NativeKitError;
import haxeon.platform.resource.Resource;
import haxeon.platform.resource.ResourceAsset;
import nativekit.ffi.NativeKit;
import nativekit.ffi.NativeKitAudio;
import nativekit.ffi.NativeKitAudioTypes;
import nativekit.ffi.NativeKitTypes;

/** Reusable audio source that can create multiple independent voices. */
class Clip implements Disposable {
	final value:ClipHandle;
	final owned:OwnedClipHandle;
	var disposed:Bool = false;

	private function new(owned:OwnedClipHandle) {
		this.owned = owned;
		this.value = owned.borrow();
	}

	public static function fromFile(path:String):Clip {
		if (path == null || path.length == 0)
			throw BindingError.invalidArgument("Clip.fromFile", "Audio clip path must not be empty");
		var made = NativeKitAudio.nk_audio_clip_create_from_file(path);
		AudioResult.check(made.status, "audio.clip.fromFile");
		return new Clip(made.out_clip);
	}

	/** Creates a clip from a ready asset in the core resource cache. */
	public static function fromAsset(asset:ResourceAsset):Clip {
		if (asset == null)
			throw BindingError.invalidArgument("Clip.fromAsset", "Audio clip resource asset must not be null");
		var made = NativeKitAudio.nk_audio_clip_create_from_asset(asset.nativeHandle());
		AudioResult.check(made.status, "audio.clip.fromAsset");
		return new Clip(made.out_clip);
	}

	/** Creates a streaming clip backed by independent provider streams. */
	public static function fromStream(resource:Resource):Clip {
		if (resource == null)
			throw BindingError.invalidArgument("Clip.fromStream", "Audio streaming resource must not be null");
		var made = NativeKitAudio.nk_audio_clip_create_from_stream(resource.nativeValue());
		AudioResult.check(made.status, "audio.clip.fromStream");
		return new Clip(made.out_clip);
	}

	public static function fromMemory(data:Bytes):Clip {
		if (data == null || data.length == 0)
			throw BindingError.invalidArgument("Clip.fromMemory", "Audio clip data must not be empty");
		var made = NativeKitAudio.nk_audio_clip_create_from_memory(data, data.length);
		AudioResult.check(made.status, "audio.clip.fromMemory");
		return new Clip(made.out_clip);
	}

	/** Creates a clip from complete, interleaved mono or stereo PCM frames. */
	public static function fromPcm(data:Bytes, sampleRate:Int, channels:Int, format:PcmFormat):Clip {
		if (data == null || data.length == 0 || format == null || sampleRate <= 0 || (channels != 1 && channels != 2))
			throw BindingError.invalidArgument("Clip.fromPcm",
				"PCM data, sample rate, channel count, or format is invalid");
		var sampleSize = switch format {
			case Unsigned8: 1;
			case Signed16LE: 2;
			case Float32LE: 4;
		};
		if (data.length % (channels * sampleSize) != 0)
			throw BindingError.invalidArgument("Clip.fromPcm", "PCM data must contain complete frames");
		var encoding = switch format {
			case Unsigned8: NativePcmFormat.U8;
			case Signed16LE: NativePcmFormat.S16Le;
			case Float32LE: NativePcmFormat.F32Le;
		};
		var made = NativeKitAudio.nk_audio_clip_create_from_pcm(data, data.length, sampleRate, channels, encoding);
		AudioResult.check(made.status, "audio.clip.fromPcm");
		return new Clip(made.out_clip);
	}

	public function nativeHandle():ClipHandle {
		ensureLive();
		return value;
	}

	public function createVoice(?options:VoiceOptions):Voice {
		ensureLive();
		return Voice.fromClip(this, options);
	}

	/** Releases the clip; existing voices retain their source. */
	public function dispose():Void {
		if (disposed)
			return;
		var status = owned.close();
		disposed = true;
		if (status != null && status != Result.Ok)
			throw new NativeKitError(status, "audio.clip.dispose", NativeKit.nk_last_error());
	}

	public function isDisposed():Bool
		return disposed;

	function ensureLive():Void {
		if (disposed)
			throw BindingError.disposed("Clip.ensureLive", "Audio clip has been disposed");
	}
}
