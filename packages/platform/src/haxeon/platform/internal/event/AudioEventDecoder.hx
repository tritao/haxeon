package haxeon.platform.internal.event;

import haxeon.platform.event.PlatformEvent;
import haxeon.platform.internal.event.EventSnapshot;
import nativekit.ffi.NativeKitTypes.EventKind;

/** Decodes lifecycle, completion, and concurrency events emitted by the optional audio module. */
class AudioEventDecoder {
	public static function decode(c:EventSnapshot):Null<PlatformEvent>
		return switch c.kind {
			case EventKind.AudioClipReady: AudioClipReady(c.source, c.request);
			case EventKind.AudioClipLoadFailed: AudioClipLoadFailed(c.source, c.request, c.result);
			case EventKind.AudioVoiceReady: AudioVoiceReady(c.source);
			case EventKind.AudioVoiceLoadFailed: AudioVoiceLoadFailed(c.source, c.result);
			case EventKind.AudioVoiceComplete: AudioVoiceComplete(c.source);
			case EventKind.AudioVoiceStolen: AudioVoiceStolen(c.source);
			case EventKind.AudioVoiceVirtualized: AudioVoiceVirtualized(c.source);
			case EventKind.AudioVoiceResumed: AudioVoiceResumed(c.source);
			case EventKind.AudioVoiceStreamFailed: AudioVoiceStreamFailed(c.source, c.result);
			case EventKind.AudioDeviceStarted: AudioDeviceStarted;
			case EventKind.AudioDeviceStopped: AudioDeviceStopped;
			case EventKind.AudioDeviceRerouted: AudioDeviceRerouted;
			case EventKind.AudioDeviceInterruptionBegan: AudioDeviceInterruptionBegan;
			case EventKind.AudioDeviceInterruptionEnded: AudioDeviceInterruptionEnded;
			default: null;
		}
}
