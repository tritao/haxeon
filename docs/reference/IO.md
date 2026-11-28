# Streams

`std.io.Reader` and `std.io.Writer` are a source and a sink of bytes, read and written a part at a time. A file
(`FileHandle.reader()`, `FileHandle.writer()`) and a child's streams (`ChildOutput`, `ChildInput`) are ones; code that
takes a `Reader` or a `Writer` works with each.

```haxe
import std.io.Reader;

/** How many lines a source holds, whatever it fails with. */
function lines<E>(source:Reader<E>):Result<Int, E> {
	var text = try source.readText();
	return Ok(text.split("\n").length);
}
```

A stream's failures are its own: `Reader<E>` and `Writer<E>` fail with `E`, a `FileError` for a file and a
`ProcessError` for a child.

| Method | Does |
| --- | --- |
| `read(buffer, offset, length)` | reads up to `length` bytes into `buffer` from `offset` (by default to its end): how many it read, which may be fewer than asked, and 0 at the source's end |
| `readAll()` | reads to the end, and answers all of it |
| `readText()` | reads to the end, and answers it as UTF-8 text |
| `write(buffer, offset, length)` | writes `length` bytes of `buffer` from `offset` (by default all of it), every one of them |
| `writeText(text)` | writes `text` as UTF-8 |

A range outside the buffer is a misuse, and throws.

## Writing a stream

`Reader` and `Writer` are abstract classes. A source extends `Reader` and writes `readRange(buffer, offset, length)`,
which `read` calls with a range it has checked and that is not empty; a sink extends `Writer` and writes
`writeRange`. The other methods come with them.

```haxe
import std.bytes.Bytes;
import std.io.Reader;

/** The same byte, forever. */
class Repeat extends Reader<Void> {
	final value:Int;

	public function new(value:Int)
		this.value = value;

	function readRange(buffer:Bytes, offset:Int, length:Int):Result<Int, Void> {
		buffer.fill(offset, length, value);
		return Ok(length);
	}
}
```
