import haxe.Int64;
import haxe.io.Bytes;
import std.fs.FileError;
import std.fs.FileHandle;
import std.fs.Files;
import std.fs.Root;

// A std.fs.FileHandle reads and writes a file a part at a time: each mode opens as it says, the position moves with
// reads, writes and seeks, the length can be set, and every failure is a FileError. On Wasm the file is in memory.

function failure<T>(result:Result<T, FileError>):String
	return switch result {
		case Ok(_): "ok";
		case Err(error): error.describe();
	}

function text(handle:FileHandle, length:Int):String {
	var buffer = Bytes.alloc(length);
	var read = handle.read(buffer).unwrap();
	return buffer.getString(0, read);
}

function opening():Int {
	if (failure(FileHandle.open("out/std-fs-handle/missing.txt", Read)) != "not found"
		|| failure(FileHandle.open("out/std-fs-handle/missing.txt", ReadWrite)) != "not found"
		|| failure(FileHandle.open("out/std-fs-handle", Read)) != "is a directory"
		|| failure(FileHandle.open("out/std-fs-handle/none/file.txt", Write)) != "not found")
		return 1;
	Files.writeText("out/std-fs-handle/kept.txt", "kept").unwrap();
	if (failure(FileHandle.open("out/std-fs-handle/kept.txt", CreateNew)) != "already exists"
		|| Files.readText("out/std-fs-handle/kept.txt").unwrapOr("") != "kept")
		return 2;
	return 0;
}

function writing():Int {
	var handle = FileHandle.open("out/std-fs-handle/data.bin", Write).unwrap();
	if (failure(handle.writeText("hello ")) != "ok" || failure(handle.writeText("world")) != "ok"
		|| handle.position().unwrap() != Int64.ofInt(11) || handle.size().unwrap() != Int64.ofInt(11))
		return 10;
	// Part of a buffer.
	if (failure(handle.write(Bytes.ofString("[!!]"), 1, 2)) != "ok" || failure(handle.sync()) != "ok")
		return 11;
	if (failure(handle.close()) != "ok" || failure(handle.close()) != "ok" || !handle.isClosed())
		return 12;
	if (Files.readText("out/std-fs-handle/data.bin").unwrapOr("") != "hello world!!")
		return 13;
	// Write empties the file it opens.
	var again = FileHandle.open("out/std-fs-handle/data.bin", Write).unwrap();
	again.writeText("short").unwrap();
	again.close().unwrap();
	if (Files.readText("out/std-fs-handle/data.bin").unwrapOr("") != "short")
		return 14;
	return 0;
}

function reading():Int {
	var handle = FileHandle.open("out/std-fs-handle/data.bin", Read).unwrap();
	if (text(handle, 3) != "sho" || text(handle, 10) != "rt" || text(handle, 10) != "")
		return 20;
	if (handle.seek(1).unwrap() != Int64.ofInt(1) || text(handle, 2) != "ho")
		return 21;
	if (handle.seek(-2, End).unwrap() != Int64.ofInt(3) || text(handle, 5) != "rt")
		return 22;
	if (handle.seek(-4, Current).unwrap() != Int64.ofInt(1) || failure(handle.seek(-5, Current)) == "ok")
		return 23;
	// Reading into the middle of a buffer.
	handle.seek(0).unwrap();
	var buffer = Bytes.ofString("......");
	if (handle.read(buffer, 2, 3).unwrap() != 3 || buffer.toString() != "..sho.")
		return 24;
	if (failure(handle.writeText("x")) == "ok")
		return 25;
	var threw = false;
	try
		_ = handle.read(buffer, 4, 5)
	catch (error:haxe.Exception)
		threw = true;
	if (!threw)
		return 26;
	handle.close().unwrap();
	threw = false;
	try
		_ = handle.size()
	catch (error:haxe.Exception)
		threw = true;
	return threw ? 0 : 27;
}

function updating():Int {
	var handle = FileHandle.open("out/std-fs-handle/data.bin", ReadWrite).unwrap();
	if (text(handle, 2) != "sh" || failure(handle.writeText("ORT")) != "ok")
		return 30;
	if (failure(handle.setLength(8)) != "ok" || handle.size().unwrap() != Int64.ofInt(8)
		|| handle.position().unwrap() != Int64.ofInt(5))
		return 31;
	handle.seek(0).unwrap();
	var all = Bytes.alloc(8);
	if (handle.read(all).unwrap() != 8 || all.getString(0, 5) != "shORT" || all.get(7) != 0)
		return 32;
	if (failure(handle.setLength(2)) != "ok" || handle.size().unwrap() != Int64.ofInt(2))
		return 33;
	handle.close().unwrap();
	if (Files.readText("out/std-fs-handle/data.bin").unwrapOr("") != "sh")
		return 34;
	return 0;
}

function appending():Int {
	for (part in ["a", "b"]) {
		var handle = FileHandle.open("out/std-fs-handle/log.txt", Append).unwrap();
		// Every write goes to the end, wherever the position was moved.
		handle.seek(0).unwrap();
		handle.writeText(part).unwrap();
		handle.close().unwrap();
	}
	if (Files.readText("out/std-fs-handle/log.txt").unwrapOr("") != "ab")
		return 40;
	var created = FileHandle.open("out/std-fs-handle/new.txt", CreateNew).unwrap();
	created.writeText("new").unwrap();
	created.dispose();
	if (Files.readText("out/std-fs-handle/new.txt").unwrapOr("") != "new")
		return 41;
	return 0;
}

function rooted():Int {
	var root = Root.open("out/std-fs-handle").unwrap();
	if (failure(root.openFile("../secret.txt", Read)) != "escapes the root"
		|| failure(root.openFile("/etc/hosts", Read)) != "escapes the root")
		return 50;
	var handle = root.openFile("log.txt", Read).unwrap();
	var read = text(handle, 10);
	handle.close().unwrap();
	root.close();
	return read == "ab" ? 0 : 51;
}

function main():Int {
	Files.removeTree("out/std-fs-handle").unwrap();
	Files.createDirectory("out/std-fs-handle").unwrap();
	var failed = 0;
	for (step in [opening, writing, reading, updating, appending, rooted])
		if (failed == 0)
			failed = step();
	Files.removeTree("out/std-fs-handle").unwrap();
	return failed == 0 ? 42 : failed;
}
