/* Copyright (C)2005-2019 Haxe Foundation. Licensed under the MIT License; see ../../../LICENSE. */

package haxe.io;

/** Byte input API over the compiler-owned native stream representation. */
extern abstract BytesInput(hl.Abstract<"realtime_bytes_input">) {
	@:hlNative("haxeon_runtime", "__bytes_input_new")
	public function new(bytes:Bytes);

	@:hlNative("haxeon_runtime", "__bytes_input_read_byte")
	public function readByte():Int;

	@:hlNative("haxeon_runtime", "__bytes_input_read_i32")
	public function readInt32():Int;

	@:hlNative("haxeon_runtime", "__bytes_input_read_f64")
	public function readDouble():Float;

	@:hlNative("haxeon_runtime", "__bytes_input_read_string")
	public function readString(length:Int):String;

	@:hlNative("haxeon_runtime", "__bytes_input_read")
	public function read(length:Int):Bytes;
}
