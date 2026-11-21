package haxe.io;

@:hlNative("haxeon_runtime", "__bytes_sub")
extern function copyRange(bytes:Bytes, pos:Int, len:Int):Bytes;

@:hlNative("haxeon_runtime", "__bytes_get_string")
extern function decodeRange(bytes:Bytes, pos:Int, len:Int):String;

/**
 * The Bytes methods that check a range and throw Haxe's `haxe.io.Error.OutsideBounds` outside it, written in Haxe once for every
 * target: `sub`, `getString`, and the throw of the writers the runtime checks. The compiler maps each method to its function here
 * (`PlatformAbi`) and loads this module with `haxe.io.Bytes`, as almost every use of Bytes calls one.
 */
function sub(bytes:Bytes, pos:Int, len:Int):Bytes {
	// `len > length - pos` rather than `pos + len > length`, which overflows for a large len.
	if (pos < 0 || len < 0 || len > bytes.length - pos)
		throw Error.OutsideBounds;
	return copyRange(bytes, pos, len);
}

function getString(bytes:Bytes, pos:Int, len:Int):String {
	if (pos < 0 || len < 0 || len > bytes.length - pos)
		throw Error.OutsideBounds;
	return decodeRange(bytes, pos, len);
}

/** What the writers the runtime checks (`set`, `setInt32`, `setFloat`, `setDouble`, `blit`) throw outside the bytes. */
function outsideBounds():Void
	throw Error.OutsideBounds;
