import haxe.io.Bytes;
import runtime.NativeCallError;
import runtime.NativeLibrary;
import runtime.NativeType;

class NativeCallMain {
	static function main():Void {
		var library = NativeLibrary.open(Sys.args()[0]);
		var add = library.resolve("native_fixture_add", [NativeType.I32, NativeType.I32], NativeType.I32);
		if (add.callI32([19, 23]) != 42)
			throw "native integer call returned the wrong value";
		var multiply = library.resolve("native_fixture_multiply", [NativeType.F64, NativeType.F64], NativeType.F64);
		if (multiply.callF64([6.0, 7.0]) != 42.0)
			throw "native double call returned the wrong value";
		var isNull = library.resolve("native_fixture_is_null", [NativeType.Pointer], NativeType.I32);
		if (isNull.callRaw(Bytes.alloc(8)).getInt32(0) != 42)
			throw "native pointer call returned the wrong value";
		var missingRejected = false;
		try
			library.resolve("native_fixture_missing", [], NativeType.Void)
		catch (_:NativeCallError)
			missingRejected = true;
		if (!missingRejected)
			throw "missing native symbol was accepted";
		library.close();
		if (add.callI32([40, 2]) != 42)
			throw "resolved function did not retain its library";
		var closedRejected = false;
		try
			library.resolve("native_fixture_add", [NativeType.I32, NativeType.I32], NativeType.I32)
		catch (_:NativeCallError)
			closedRejected = true;
		if (!closedRejected)
			throw "closed native library resolved a new function";
		Sys.println("PASS: ordinary C symbols load and invoke through the native call bridge");
	}
}
