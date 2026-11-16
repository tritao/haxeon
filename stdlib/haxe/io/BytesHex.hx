package haxe.io;

/**
 * `bytes.toHex()`: the bytes as lowercase hexadecimal, as Haxe's Bytes.toHex. Written in Haxe once for every target; the
 * compiler maps the method to this function (`PlatformAbi`) and loads this module only where a program calls it, so the
 * Bytes module every program loads stays free of what this one uses.
 */
function toHex(bytes:Bytes):String {
	var digits = "0123456789abcdef", text = new StringBuf();
	for (index in 0...bytes.length) {
		var value = bytes.get(index);
		text.addChar(digits.charCodeAt(value >> 4));
		text.addChar(digits.charCodeAt(value & 15));
	}
	return text.toString();
}
