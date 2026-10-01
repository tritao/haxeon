package haxeon.wasm;

import haxe.io.Bytes;
import haxeon.wasm.HaxeonHost;

/** A callback handle is the host function-table index it was given; both Wasm backends keep it as an i32. */
@:hlNative("haxeon_runtime", "nativeCallbackFromIndex")
extern function handleOf(index:Int):hl.Abstract<"native_callback">;

@:hlNative("haxeon_runtime", "nativeCallbackIndex")
extern function indexOf(callback:hl.Abstract<"native_callback">):Int;

/**
 * Closures a Wasm guest hands to native code as C function pointers.
 *
 * Generated HXI callback types register their closure here and ask the host for a function-table entry that
 * calls the type's exported entry function with the closure's id. Native code only ever sees the table index.
 * A closure's exception cannot unwind through native frames, so the entry function records it here for
 * errorKind and takeError.
 */
class Callbacks {
	static final closures:Array<Dynamic> = [null];
	static final tableIndices:Array<Int> = [0];
	static final errors:Array<Null<String>> = [null];
	static final freeIds:Array<Int> = [];

	/** Registers a closure and returns the handle native code calls it through. */
	public static function create(entry:String, signature:String, closure:Dynamic):hl.Abstract<"native_callback"> {
		var id = freeIds.length > 0 ? freeIds.pop() : closures.length;
		if (id == closures.length) {
			closures.push(null);
			tableIndices.push(0);
			errors.push(null);
		}
		closures[id] = closure;
		errors[id] = null;
		var index = HaxeonHost.callback_create(entry, signature, id);
		tableIndices[id] = index;
		return handleOf(index);
	}

	/** The closure an entry function was called for. */
	public static function closure(id:Int):Dynamic
		return closures[id];

	/** Records an exception thrown by the closure with this id. */
	public static function fail(id:Int, error:Dynamic):Void
		errors[id] = Std.string(error);

	public static function close(callback:hl.Abstract<"native_callback">):Bool {
		var index = indexOf(callback), id = idOf(index);
		if (id == 0)
			return false;
		HaxeonHost.callback_close(index);
		closures[id] = null;
		tableIndices[id] = 0;
		errors[id] = null;
		freeIds.push(id);
		return true;
	}

	/** 1 while the closure behind this handle has an unread exception, 0 otherwise. */
	public static function errorKind(callback:hl.Abstract<"native_callback">):Int {
		var id = idOf(indexOf(callback));
		return id != 0 && errors[id] != null ? 1 : 0;
	}

	public static function takeError(callback:hl.Abstract<"native_callback">):Null<Bytes> {
		var id = idOf(indexOf(callback));
		if (id == 0 || errors[id] == null)
			return null;
		var error = errors[id];
		errors[id] = null;
		return Bytes.ofString(error);
	}

	static function idOf(index:Int):Int {
		if (index != 0)
			for (id in 1...tableIndices.length)
				if (tableIndices[id] == index && closures[id] != null)
					return id;
		return 0;
	}
}
