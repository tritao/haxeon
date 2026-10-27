package haxeon.platform.internal.event;

import haxeon.platform.BindingError;
import haxeon.platform.event.PlatformEvent;
import haxeon.platform.internal.event.AudioEventDecoder;
import haxeon.platform.internal.event.EventSnapshot;
import haxeon.platform.internal.event.HttpEventDecoder;
import haxeon.platform.internal.event.InputEventDecoder;
import haxeon.platform.internal.event.ResourceEventDecoder;
import haxeon.platform.internal.event.ServiceEventDecoder;
import haxeon.platform.internal.event.WindowEventDecoder;
import nativekit.ffi.NativeKit;
import nativekit.ffi.NativeKitTypes.Event;
import nativekit.ffi.NativeKitTypes.EventKind;
import nativekit.ffi.NativeKitTypes.Handle;
import nativekit.ffi.NativeKitTypes.Result;

/** Owns one polled NativeKit event and releases its native payload exactly once. */
class NativeEvent {
	final event:Event;
	public final kind:EventKind;
	public final source:Handle;
	public final request:haxe.Int64;
	public final result:Result;
	public final flags:Int;
	public final dataCount:Int;
	public final dataSize:haxe.Int64;
	var released:Bool;

	@:allow(haxeon.platform.event.EventPump)
	private function new(event:Event) {
		this.event = event;
		kind = event.get_kind(); source = event.get_source(); request = event.get_request_id();
		result = event.get_result(); flags = event.get_flags(); dataCount = event.get_data_count(); dataSize = event.get_data_size();
		released = false;
	}

	/** Copies the native payload. The returned bytes remain valid after release. */
	public function payload():haxe.io.Bytes {
		ensureOpen();
		return event.get_data_bytes();
	}

	/** Creates a managed decoder snapshot which remains valid after release. */
	public function snapshot():EventSnapshot
		return new EventSnapshot(kind, source, request, result, flags, dataCount,
			kind == EventKind.None ? haxe.io.Bytes.alloc(0) : payload());

	/** Decodes a managed event snapshot without retaining native memory. */
	public static function decodeSnapshot(context:EventSnapshot):PlatformEvent {
		if (context.kind == EventKind.None)
			return None;
		var value = WindowEventDecoder.decode(context);
		if (value == null) value = InputEventDecoder.decode(context);
		if (value == null) value = AudioEventDecoder.decode(context);
		if (value == null) value = ServiceEventDecoder.decode(context);
		if (value == null) value = ResourceEventDecoder.decode(context);
		return value != null ? value : Raw(context.kind, context.source, context.request,
			context.result, context.flags, context.dataCount, context.data);
	}

	/** Decodes known event formats without releasing this event. */
	public function decode():PlatformEvent {
		if (kind == EventKind.HttpHeaders || kind == EventKind.HttpComplete ||
			kind == EventKind.HttpDataAvailable || kind == EventKind.HttpProgress)
			return HttpEventDecoder.decode(this);
		return decodeSnapshot(snapshot());
	}

	@:allow(haxeon.platform.internal.event.HttpEventDecoder)
	private function nativeEvent():Event {
		ensureOpen();
		return event;
	}

	/** Decodes and releases the event, including when decoding throws. */
	public function take():PlatformEvent {
		var value:PlatformEvent;
		try value = decode() catch (error:Dynamic) {
			release();
			throw error;
		}
		release();
		return value;
	}

	/** Releases the native payload. Returns false after the first release. */
	public function release():Bool {
		if (released) return false;
		NativeKit.nk_event_release(event);
		released = true;
		return true;
	}

	public function isReleased():Bool return released;

	function ensureOpen():Void
		if (released) throw BindingError.disposed("NativeEvent.ensureOpen", "NativeKit event has already been released");
}
