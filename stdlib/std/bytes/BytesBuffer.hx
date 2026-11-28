/* Copyright (C)2005-2019 Haxe Foundation. Licensed under the MIT License; see ../../../LICENSE. */

package std.bytes;

import std.bytes.BytesBounds.outsideBounds;
import std.bytes.Encoding;

@:hlNative("haxeon_runtime", "__string_utf8_length")
internal extern function stringUtf8Length(value:String):Int;

@:hlNative("haxeon_runtime", "__bytes_set_utf8")
internal extern function bytesSetUtf8(bytes:Bytes, pos:Int, value:String):Void;

/**
 * An append-only buffer of bytes, as in Haxe: build a `Bytes` from pieces, then take it with `getBytes`. Numbers are added
 * little-endian. Haxe leaves using a buffer after `getBytes` undefined; here the bytes taken are shared until the next
 * addition, which copies them first, so what `getBytes` returned never changes and taking costs no copy.
 */
class BytesBuffer {
	var b:Bytes;
	var pos = 0;

	/** Whether `getBytes` handed out `b`, so it must be copied before it changes. */
	var shared = false;

	/** The number of bytes added so far. */
	public var length(get, never):Int;

	/** An empty buffer. */
	public function new()
		b = Bytes.alloc(64);

	function get_length():Int
		return pos;

	/** The storage, writable, with room for `extra` more bytes. */
	inline function room(extra:Int):Bytes
		return pos + extra <= b.length && !shared ? b : grow(b, extra);

	/** New storage with room for `extra` more bytes, holding what was added. */
	function grow(bytes:Bytes, extra:Int):Bytes {
		shared = false;
		var capacity = bytes.length < 64 ? 64 : bytes.length;
		while (capacity < pos + extra)
			capacity *= 2;
		var grown = Bytes.alloc(capacity);
		grown.blit(0, bytes, 0, pos);
		b = grown;
		return grown;
	}

	/** Adds the byte `byte`, its low 8 bits. */
	public inline function addByte(byte:Int):Void
		room(1).set(pos++, byte);

	/** Adds all of `src`. */
	public function add(src:Bytes):Void
		addBytes(src, 0, src.length);

	/** Adds `v` in `encoding`: UTF-8 by default, or its UTF-16 code units (`Bytes.ofString`). */
	public function addString(v:String, encoding:Encoding = Utf8):Void {
		if (encoding != Utf8) {
			add(Bytes.ofString(v, encoding));
			return;
		}
		var size = stringUtf8Length(v);
		bytesSetUtf8(room(size), pos, v);
		pos += size;
	}

	/** Adds `v` as 4 bytes, little-endian. */
	public inline function addInt32(v:Int):Void {
		room(4).setInt32(pos, v);
		pos += 4;
	}

	/** Adds `v` as 8 bytes, little-endian. */
	public function addInt64(v:haxe.Int64):Void {
		addInt32(haxe.Int64.toInt(v));
		addInt32(haxe.Int64.toInt(haxe.Int64.shr(v, 32)));
	}

	/** Adds `v` as a 32-bit IEEE float, little-endian. */
	public function addFloat(v:Float):Void {
		room(4).setFloat(pos, v);
		pos += 4;
	}

	/** Adds `v` as a 64-bit IEEE float, little-endian. */
	public function addDouble(v:Float):Void {
		room(8).setDouble(pos, v);
		pos += 8;
	}

	/** Adds `len` bytes of `src` from `pos`; throws when they are not all in `src`. */
	public function addBytes(src:Bytes, pos:Int, len:Int):Void {
		// `len > length - pos` rather than `pos + len > length`, which overflows for a large len.
		if (pos < 0 || len < 0 || len > src.length - pos)
			outsideBounds();
		room(len).blit(this.pos, src, pos, len);
		this.pos += len;
	}

	/** The bytes added so far, without copying them. */
	public function getBytes():Bytes {
		shared = true;
		return Bytes.view(b, 0, pos);
	}
}
