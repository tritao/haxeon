/* Copyright (C)2005-2019 Haxe Foundation. Licensed under the MIT License; see ../../../LICENSE. */

package haxe.io;

/** How a String is stored as bytes. Strings are UTF-8 here, so both choices write the same bytes. */
enum Encoding {
	UTF8;
	RawNative;
}
