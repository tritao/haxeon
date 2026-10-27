package haxeon.platform.internal.event;

import nativekit.ffi.NativeKitTypes.EventKind;
import nativekit.ffi.NativeKitTypes.Handle;
import nativekit.ffi.NativeKitTypes.Result;

/** Managed payload snapshot whose storage remains valid after the native event is released. */

class EventSnapshot {
	public final kind:EventKind;
	public final source:Handle;
	public final request:haxe.Int64;
	public final result:Result;
	public final flags:Int;
	public final dataCount:Int;
	public final data:haxe.io.Bytes;

	public function new(kind:EventKind, source:Handle, request:haxe.Int64, result:Result,
		flags:Int, dataCount:Int, data:haxe.io.Bytes) {
		this.kind = kind;
		this.source = source;
		this.request = request;
		this.result = result;
		this.flags = flags;
		this.dataCount = dataCount;
		this.data = data;
	}
}
