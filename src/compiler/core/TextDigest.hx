package compiler.core;

import haxe.crypto.Sha256;
import haxe.io.Bytes;

/**
 * The lowercase hex SHA-256 of a string's UTF-8 bytes. Stock Haxe's `Sha256.encode` pads a non-ASCII string by its UTF-16
 * length, so its digest is not the SHA-256 and differs from Haxeon's; hashing the bytes gives one name in both builds.
 */
class TextDigest {
	public static function sha256(text:String):String
		return Sha256.make(Bytes.ofString(text)).toHex();
}
