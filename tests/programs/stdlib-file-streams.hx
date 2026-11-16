import haxe.io.Bytes;
import haxe.io.Eof;
import sys.io.File;
import sys.io.FileSeek;

// File.write, append, update and read stream a file as Haxe's do, on HashLink files and Wasm's in-memory file system alike.
function main():Int {
	sys.FileSystem.createDirectory("out");
	var path = "out/stdlib-file-streams.txt";
	var output = File.write(path);
	output.writeString("first λ\n");
	output.writeByte("s".code);
	output.writeBytes(Bytes.ofString("econd\r\n"), 0, 7);
	output.close();
	var appended = File.append(path);
	appended.writeString("last");
	appended.close();
	if (File.getContent(path) != "first λ\nsecond\r\nlast")
		return 1;
	var input = File.read(path);
	if (input.readLine() != "first λ" || input.readLine() != "second" || input.readLine() != "last")
		return 2;
	try {
		input.readLine();
		return 3;
	} catch (_:Eof) {}
	if (!input.eof())
		return 4;
	input.seek(0, SeekBegin);
	if (input.readString(5) != "first" || input.tell() != 5)
		return 5;
	input.seek(-4, SeekEnd);
	if (input.readAll().toString() != "last")
		return 6;
	input.close();
	// write truncates what was there.
	var again = File.write(path);
	again.writeString("short");
	again.close();
	if (File.getContent(path) != "short")
		return 7;
	try {
		File.read("out/stdlib-file-streams-missing.txt");
		return 8;
	} catch (_:Dynamic) {}
	// update writes over the file from a position and keeps the rest; an output knows where it is.
	var written = File.write(path);
	written.writeString("hello world");
	if (written.tell() != 11)
		return 9;
	written.close();
	var updated = File.update(path);
	updated.seek(6, SeekBegin);
	updated.writeString("WORLD");
	if (updated.tell() != 11)
		return 10;
	updated.seek(0, SeekBegin);
	updated.writeByte("H".code);
	updated.close();
	if (File.getContent(path) != "Hello WORLD")
		return 11;
	// Appending writes at the end wherever the position was moved.
	var appending = File.append(path);
	appending.seek(0, SeekBegin);
	appending.writeString("!");
	appending.close();
	if (File.getContent(path) != "Hello WORLD!")
		return 12;
	try {
		File.update("out/stdlib-file-streams-missing.txt");
		return 13;
	} catch (_:Dynamic) {}
	return 42;
}
