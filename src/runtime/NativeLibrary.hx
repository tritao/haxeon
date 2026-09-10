package runtime;

import haxe.io.Bytes;

/** Explicitly owned dynamic library used for ordinary C ABI calls. */
class NativeLibrary {
	var handle:Null<hl.Abstract<"native_library">>;

	/** Opens a logical library name or an explicit filename/path.
		Logical names receive the platform's native prefix and extension. */
	public static function open(path:String):NativeLibrary {
		var encoded = Bytes.ofString(path),
			handle = NativeCallApi.native_open(encoded.getData(), encoded.length);
		if (handle == null)
			throw new NativeCallError(NativeCallApi.lastError());
		return new NativeLibrary(handle);
	}

	function new(handle:hl.Abstract<"native_library">) {
		this.handle = handle;
	}

	/** Resolve and prepare a typed symbol. Existing functions survive library close. */
	public function resolve(symbol:String, arguments:Array<NativeType>, result:NativeType):NativeFunction {
		if (handle == null)
			throw new NativeCallError("Native library is closed");
		var encodedSymbol = Bytes.ofString(symbol),
			encodedTypes = Bytes.alloc(arguments.length);
		for (index in 0...arguments.length)
			encodedTypes.set(index, arguments[index]);
		var resolved = NativeCallApi.native_resolve(handle, encodedSymbol.getData(), encodedSymbol.length, encodedTypes.getData(), encodedTypes.length, result);
		if (resolved == null)
			throw new NativeCallError(NativeCallApi.lastError());
		return new NativeFunction(resolved, arguments, result);
	}

	/** Release this wrapper's ownership. Already-resolved functions remain valid. */
	public function close():Void {
		if (handle == null)
			return;
		NativeCallApi.native_close(handle);
		handle = null;
	}
}
