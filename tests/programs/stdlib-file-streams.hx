import haxe.io.Bytes;
import haxe.io.Eof;
import sys.io.File;
import sys.io.FileSeek;

// File.write, append and read stream a file as Haxe's do, on HashLink files and Wasm's in-memory file system alike.
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
	return 42;
}
