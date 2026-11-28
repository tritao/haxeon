package haxeon.platform.event;

import haxeon.platform.NativeKitError;
import haxeon.platform.NativeKitStatus;
import nativekit.ffi.NativeKitTypes.EventKind;

/** Decodes lifecycle, completion, and concurrency events emitted by the optional audio module. */
internal class AudioEventDecoder {
	public static function decode(c:EventSnapshot):Null<PlatformEvent>
		return switch c.kind {
			case EventKind.AudioClipReady: AudioClipReady(c.source, c.request);
			case EventKind.AudioClipLoadFailed: AudioClipLoadFailed(c.source, c.request, failure(c));
			case EventKind.AudioVoiceReady: AudioVoiceReady(c.source);
			case EventKind.AudioVoiceLoadFailed: AudioVoiceLoadFailed(c.source, failure(c));
			case EventKind.AudioVoiceComplete: AudioVoiceComplete(c.source);
			case EventKind.AudioVoiceStolen: AudioVoiceStolen(c.source);
			case EventKind.AudioVoiceVirtualized: AudioVoiceVirtualized(c.source);
			case EventKind.AudioVoiceResumed: AudioVoiceResumed(c.source);
			case EventKind.AudioVoiceStreamFailed: AudioVoiceStreamFailed(c.source, failure(c));
			case EventKind.AudioDeviceStarted: AudioDeviceStarted;
			case EventKind.AudioDeviceStopped: AudioDeviceStopped;
			case EventKind.AudioDeviceRerouted: AudioDeviceRerouted;
			case EventKind.AudioDeviceInterruptionBegan: AudioDeviceInterruptionBegan;
			case EventKind.AudioDeviceInterruptionEnded: AudioDeviceInterruptionEnded;
			default: null;
		}

	static function failure(c:EventSnapshot):NativeKitError
		return NativeKitStatus.reported(c.result, null);
}
