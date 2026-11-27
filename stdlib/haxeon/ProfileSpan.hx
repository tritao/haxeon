package haxeon;

/** Named spans recorded in a HashLink diagnostics profiler capture. */
class ProfileSpan {
	static inline var SPAN_BEGIN = 0x484C1001;
	static inline var SPAN_END = 0x484C1002;

	/** Marks the start of a span named `name` on the current thread, which `end` with the same name closes. */
	public static function begin(name:String):Void emit(SPAN_BEGIN, name);

	/** Marks the end of the span named `name` that `begin` started on the current thread. */
	public static function end(name:String):Void emit(SPAN_END, name);

	static function emit(code:Int, name:String):Void {
		nativeProfileSpan(code, name);
	}
}

#if wasm
// Browser builds have no HashLink profiler to record spans.
function nativeProfileSpan(code:Int, name:String):Void {}
#else
@:hlNative("haxeon_runtime", "__sys_profile_span")
internal extern function nativeProfileSpan(code:Int, name:String):Void;
#end
