import std.bytes.Bytes;
import std.fs.FileHandle;
import std.fs.Files;
import std.fs.OpenMode;
import std.io.Reader;
import std.io.Writer;

// std.io: a file read and written through its Reader and Writer, generic code over any source or sink, and the range checks
// every reader and writer shares.

/** What any source holds, whatever it fails with. */
function drain<E>(source:Reader<E>):String
	return switch source.readText() {
		case Ok(text): text;
		case Err(_): "<failed>";
	}

/** Writes `parts` to any sink: whether every write succeeded. */
function fill<E>(sink:Writer<E>, parts:Array<String>):Bool {
	for (part in parts)
		if (!sink.writeText(part).isOk())
			return false;
	return true;
}

function rejects(action:() -> Void):Bool {
	try {
		action();
		return false;
	} catch (_:haxe.Exception) {
		return true;
	}
}

function main():Int {
	_ = Files.removeTree("out/std-io");
	Files.createDirectory("out/std-io").unwrap();
	var path:std.fs.Path = "out/std-io/streams.txt";
	scoped var written = FileHandle.open(path, Write).unwrap();
	if (!fill(written.writer(), ["one ", "two ", "three"]))
		return 1;
	var sink = written.writer();
	if (!sink.write(Bytes.ofString("xx-four-xx"), 2, 6).isOk())
		return 2;
	written.close().unwrap();

	scoped var read = FileHandle.open(path, Read).unwrap();
	var source = read.reader();
	var head = Bytes.alloc(4);
	// A read may answer fewer bytes than asked, never more; at the end it answers 0.
	if (source.read(head).unwrap() != 4 || head.toString() != "one ")
		return 3;
	if (source.read(head, 1, 0).unwrap() != 0)
		return 4;
	if (drain(source) != "two three-four-")
		return 5;
	if (source.read(head).unwrap() != 0 || source.readAll().unwrap().length != 0)
		return 6;
	// The reader and the handle share the position.
	read.seek(4).unwrap();
	if (read.reader().readText().unwrap() != "two three-four-")
		return 7;
	if (!rejects(() -> _ = source.read(head, 3, 2)) || !rejects(() -> _ = sink.write(head, -1, 1))
		|| !rejects(() -> _ = source.read(head, 5)))
		return 8;
	read.close().unwrap();
	Files.removeTree("out/std-io").unwrap();
	return 42;
}
