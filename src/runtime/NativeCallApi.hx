package runtime;

/** Private-by-convention HashLink entry points backing the ordinary C ABI bridge. */
@:noCompletion
@:hlNative("realtime_runtime")
class NativeCallApi {
	public static function native_open(path:hl.Bytes, length:Int):hl.Abstract<"native_library">
		return null;

	public static function native_close(library:hl.Abstract<"native_library">):Bool
		return false;

	public static function native_resolve(library:hl.Abstract<"native_library">, symbol:hl.Bytes, symbolLength:Int, arguments:hl.Bytes, argumentCount:Int,
			result:Int):hl.Abstract<"native_function">
		return null;

	public static function native_call(fn:hl.Abstract<"native_function">, arguments:hl.Bytes, argumentLength:Int, output:hl.Bytes, outputLength:Int):Int
		return -1;

	public static function native_last_error(output:hl.Bytes, capacity:Int):Int
		return 0;

	public static function lastError():String {
		var output = new hl.Bytes(512),
			length = native_last_error(output, 512);
		if (length < 0)
			return "Native call failed and its diagnostic exceeded 512 bytes";
		return haxe.io.Bytes.ofData(new haxe.io.BytesData(output, length)).toString();
	}
}
