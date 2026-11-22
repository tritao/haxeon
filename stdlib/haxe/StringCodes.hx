package haxe;

#if wasm
import haxe.io.Bytes;

/**
 * `String.fromCharCode` on Wasm, whose strings are UTF-8: the code point's UTF-8 bytes, as the string HashLink makes of it (a
 * code point above U+FFFF is two UTF-16 units). A surrogate or a code past U+10FFFF throws "Invalid unicode char N", as in
 * Haxe. The compiler calls it for `String.fromCharCode` where the module defines it (`RuntimeType.STRING_FROM_CHAR_CODE`);
 * on HashLink the runtime native does the same.
 */
function fromCharCode(code:Int):String {
	if (code < 0 || code >= 0x110000 || (code >= 0xD800 && code <= 0xDFFF))
		throw "Invalid unicode char " + code;
	var length = code < 0x80 ? 1 : code < 0x800 ? 2 : code < 0x10000 ? 3 : 4, bytes = Bytes.alloc(length);
	if (length == 1)
		bytes.set(0, code);
	else {
		for (index in 1...length)
			bytes.set(index, 0x80 | ((code >> ((length - 1 - index) * 6)) & 63));
		bytes.set(0, (length == 2 ? 0xC0 : length == 3 ? 0xE0 : 0xF0) | (code >> ((length - 1) * 6)));
	}
	return bytes.toString();
}
#end
