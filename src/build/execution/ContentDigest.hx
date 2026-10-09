package build.execution;

import haxe.io.Bytes;

/** SHA-256 adapter for tools compiled with upstream Haxe and Haxeon applications. */
class ContentDigest {
	#if (hl && !haxeon)
	@:hlNative("haxeon_runtime", "__sha256_raw")
	static function nativeDigest(input:hl.Bytes, length:Int, output:hl.Bytes):Void {}
	#end

	public static function make(input:Bytes):Bytes {
		#if (hl && !haxeon)
		var output = Bytes.alloc(32);
		nativeDigest(input.getData(), input.length, output.getData());
		return output;
		#else
		return haxe.crypto.Sha256.make(input);
		#end
	}
}
