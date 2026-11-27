package haxeon.audio;

import haxeon.platform.BindingError;

import haxe.io.Bytes;
import haxeon.platform.InvalidArgumentMeans;
import haxeon.platform.NativeKitError;
import haxeon.platform.NativeKitStatus;
import haxeon.platform.resource.Resource;
import haxeon.platform.resource.ResourceAsset;
import nativekit.ffi.NativeKit;
import nativekit.ffi.NativeKitAudio;
import nativekit.ffi.NativeKitAudioTypes;
import nativekit.ffi.NativeKitTypes.Result as NativeResult;

/** Reusable audio source that can create multiple independent voices. */
class Clip implements Disposable {
	final value:ClipHandle;
	final owned:OwnedClipHandle;
	var disposed:Bool = false;

	private function new(owned:OwnedClipHandle) {
		this.owned = owned;
		this.value = owned.borrow();
	}

	/** A clip of the audio file at `path`. */
	public static function fromFile(path:String):Result<Clip, NativeKitError> {
		if (path == null || path.length == 0)
			throw BindingError.invalidArgument("Clip.fromFile", "Audio clip path must not be empty");
		var made = NativeKitAudio.nk_audio_clip_create_from_file(path);
		return NativeKitStatus.made(made.status, "audio.clip.fromFile", NativeKit.nk_last_error(),
			() -> new Clip(made.out_clip),
			RefusedInput);
	}

	/** Creates a clip from a ready asset in the core resource cache. */
	public static function fromAsset(asset:ResourceAsset):Result<Clip, NativeKitError> {
		if (asset == null)
			throw BindingError.invalidArgument("Clip.fromAsset", "Audio clip resource asset must not be null");
		var made = NativeKitAudio.nk_audio_clip_create_from_asset(asset.nativeHandle());
		return NativeKitStatus.made(made.status, "audio.clip.fromAsset", NativeKit.nk_last_error(),
			() -> new Clip(made.out_clip),
			RefusedInput);
	}

	/** Creates a streaming clip backed by independent provider streams. */
	public static function fromStream(resource:Resource):Result<Clip, NativeKitError> {
		if (resource == null)
			throw BindingError.invalidArgument("Clip.fromStream", "Audio streaming resource must not be null");
		var made = NativeKitAudio.nk_audio_clip_create_from_stream(resource.nativeValue());
		return NativeKitStatus.made(made.status, "audio.clip.fromStream", NativeKit.nk_last_error(),
			() -> new Clip(made.out_clip),
			RefusedInput);
	}

	/** A clip of the encoded audio in `data`, which it copies. */
	public static function fromMemory(data:Bytes):Result<Clip, NativeKitError> {
		if (data == null || data.length == 0)
			throw BindingError.invalidArgument("Clip.fromMemory", "Audio clip data must not be empty");
		var made = NativeKitAudio.nk_audio_clip_create_from_memory(data, data.length);
		return NativeKitStatus.made(made.status, "audio.clip.fromMemory", NativeKit.nk_last_error(),
			() -> new Clip(made.out_clip),
			RefusedInput);
	}

	/** A clip of complete, interleaved mono or stereo PCM frames, which it copies. */
	public static function fromPcm(data:Bytes, sampleRate:Int, channels:Int,
			format:PcmFormat):Result<Clip, NativeKitError> {
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
		return NativeKitStatus.made(made.status, "audio.clip.fromPcm", NativeKit.nk_last_error(),
			() -> new Clip(made.out_clip));
	}

	internal function nativeHandle():ClipHandle {
		ensureLive();
		return value;
	}

	/** A stopped voice playing the clip, configured by `options`. */
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
		if (status != null && status != NativeResult.Ok)
			throw NativeKitStatus.failure(status, "audio.clip.dispose", NativeKit.nk_last_error());
	}

	/** Whether it has been disposed. */
	public function isDisposed():Bool
		return disposed;

	function ensureLive():Void {
		if (disposed)
			throw BindingError.disposed("Clip.ensureLive", "Audio clip has been disposed");
	}
}
