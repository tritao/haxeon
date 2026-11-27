package haxe.crypto;

import haxe.io.Bytes;

/** Standard Base64 (RFC 4648) encoding with optional `=` padding. */
class Base64 {
	/** The 64 characters of the standard alphabet, in the order of the values they stand for. */
	public static inline var CHARS = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

	/** `bytes` in Base64, padded with `=` to a multiple of four characters unless `complement` is false. */
	public static function encode(bytes:Bytes, complement:Bool = true):String {
		var output = new StringBuf(), length = bytes.length, index = 0;
		while (index + 2 < length) {
			var value = (bytes.get(index) << 16) | (bytes.get(index + 1) << 8) | bytes.get(index + 2);
			output.addChar(CHARS.charCodeAt((value >> 18) & 63));
			output.addChar(CHARS.charCodeAt((value >> 12) & 63));
			output.addChar(CHARS.charCodeAt((value >> 6) & 63));
			output.addChar(CHARS.charCodeAt(value & 63));
			index += 3;
		}
		var remaining = length - index;
		if (remaining > 0) {
			var value = bytes.get(index) << 16;
			if (remaining == 2)
				value |= bytes.get(index + 1) << 8;
			output.addChar(CHARS.charCodeAt((value >> 18) & 63));
			output.addChar(CHARS.charCodeAt((value >> 12) & 63));
			if (remaining == 2)
				output.addChar(CHARS.charCodeAt((value >> 6) & 63));
			if (complement)
				output.add(remaining == 1 ? "==" : "=");
		}
		return output.toString();
	}

	/**
	 * Decodes from the text's UTF-8 bytes: indexing the String per character is linear on targets that store UTF-8
	 * (wasm32 counts UTF-16 units from the start on each `charAt`), which made a large decode quadratic.
	 */
	public static function decode(text:String, complement:Bool = true):Bytes {
		var source = Bytes.ofString(text), length = source.length;
		if (complement)
			while (length > 0 && source.get(length - 1) == "=".code)
				length--;
		var output = Bytes.alloc(Std.int(length * 6 / 8)), accumulator = 0, bits = 0, position = 0;
		for (index in 0...length) {
			var digit = digitOf(source.get(index));
			if (digit < 0)
				throw 'Invalid Base64 character at $index';
			accumulator = (accumulator << 6) | digit;
			bits += 6;
			if (bits >= 8) {
				bits -= 8;
				output.set(position++, (accumulator >> bits) & 0xFF);
			}
		}
		return output;
	}

	/** The value of a byte of `CHARS`, or -1 for any other byte (every byte of a non-ASCII character). */
	static function digitOf(code:Int):Int
		return if (code >= "A".code && code <= "Z".code) code - "A".code
			else if (code >= "a".code && code <= "z".code) code - "a".code + 26
			else if (code >= "0".code && code <= "9".code) code - "0".code + 52
			else if (code == "+".code) 62
			else if (code == "/".code) 63
			else -1;
}
