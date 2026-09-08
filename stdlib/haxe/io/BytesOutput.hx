/* Copyright (C)2005-2019 Haxe Foundation. Licensed under the MIT License; see ../../../LICENSE. */

package haxe.io;

/** Byte output API over the compiler-owned native stream representation. */
extern abstract BytesOutput(hl.Abstract<"realtime_bytes_output">) {
	@:hlNative("haxeon_runtime", "__bytes_output_new")
	public function new();

	@:hlNative("haxeon_runtime", "__bytes_output_write_byte")
	public function writeByte(value:Int):Void;

	@:hlNative("haxeon_runtime", "__bytes_output_write_i32")
	public function writeInt32(value:Int):Void;

	@:hlNative("haxeon_runtime", "__bytes_output_write_f64")
	public function writeDouble(value:Float):Void;

	@:hlNative("haxeon_runtime", "__bytes_output_write_string")
	public function writeString(value:String):Void;

	@:hlNative("haxeon_runtime", "__bytes_output_write")
	public function write(bytes:Bytes):Void;

	@:hlNative("haxeon_runtime", "__bytes_output_write")
	public function writeBytes(bytes:Bytes):Void;

	@:hlNative("haxeon_runtime", "__bytes_output_get_bytes")
	public function getBytes():Bytes;
}
