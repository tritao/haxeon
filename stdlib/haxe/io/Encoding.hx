/* Copyright (C)2005-2019 Haxe Foundation. Licensed under the MIT License; see ../../../LICENSE. */

package haxe.io;

/** How a String is stored as bytes: UTF-8, or `RawNative`, HashLink's UTF-16 code units, little-endian, on every target. */
enum Encoding {
	UTF8;
	RawNative;
}
