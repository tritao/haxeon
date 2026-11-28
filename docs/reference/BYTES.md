# Bytes

`std.bytes.Bytes` is a fixed-length sequence of bytes, read and written in place. `std.bytes.BytesBuffer` builds one
from pieces. Haxe's `haxe.io.Bytes` and `haxe.io.BytesBuffer` are the same types, so a value passes between Haxe's API
and std's as it is.

```haxe
import std.bytes.Bytes;

function header(length:Int):Bytes {
	var bytes = Bytes.alloc(8);
	bytes.setInt32(0, 0x48584E31);
	bytes.setInt32(4, length);
	return bytes;
}
```

## Making bytes

| Function | Makes |
| --- | --- |
| `Bytes.alloc(length)` | `length` zero bytes |
| `Bytes.ofString(text, encoding)` | the bytes of `text`: UTF-8 by default, or `Utf16`, its UTF-16 code units, little-endian |
| `Bytes.ofHex(text)` | the bytes two hexadecimal digits each spell, in either case; any other text throws |
| `Bytes.view(bytes, offset, length)` | a view sharing a range of `bytes`, which copies nothing |

## Reading and writing

Numbers are little-endian: `get`/`set` a byte, `getUInt16`, `getInt32`, `getInt64`, `getFloat`, `getDouble` and their
setters. `blit` copies a range from other bytes, `fill` sets a range to one value, `sub` copies a range out, `compare`
orders two by their bytes, `getString(pos, length, encoding)` decodes a range, and `toHex` spells the bytes in lowercase
hexadecimal.

A write, `sub` or `getString` outside the bytes is a misuse, and throws. A read of a number outside them answers 0.

## Buffers

`new BytesBuffer()` starts empty; `addByte`, `add`, `addBytes`, `addString(text, encoding)`, `addInt32`, `addInt64`,
`addFloat` and `addDouble` append, and `getBytes()` hands out what was added without copying it. The buffer copies its
bytes before its next addition, so what `getBytes` returned never changes.
