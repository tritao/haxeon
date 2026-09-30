import haxe.io.Bytes;
import sys.FileSystem;
import sys.io.AtomicFile;
import sys.io.File;

// The Wasm host shims: an empty environment, a "Web" system, and a session-only in-memory
// filesystem behind sys.io.File, sys.io.AtomicFile, sys.FileSystem and the Sys path calls.
function host():Int {
	return Sys.getEnv("HOME") == null && Sys.getCwd() == "/" && Sys.systemName() == "Web" && Sys.executablePath() == "" && Sys.exists("/")
		&& Sys.isDir("/") ? 0 : 1;
}

function files():Int {
	FileSystem.createDirectory("projects/demo/assets");
	if (!FileSystem.isDirectory("/projects/demo") || FileSystem.fullPath("projects//demo/./assets/../") != "/projects/demo")
		return 2;
	File.saveContent("/projects/demo/scene.json", "{\"a\":1}");
	File.appendContent("/projects/demo/scene.json", ",more");
	if (File.getContent("projects/demo/scene.json") != "{\"a\":1},more" || !FileSystem.exists("/projects/demo/scene.json"))
		return 3;
	var bytes = Bytes.alloc(3);
	bytes.set(0, 0);
	bytes.set(1, 255);
	bytes.set(2, 42);
	File.saveBytes("/projects/demo/assets/blob.bin", bytes);
	bytes.set(2, 7);
	var loaded = File.getBytes("/projects/demo/assets/blob.bin");
	if (loaded.length != 3 || loaded.get(1) != 255 || loaded.get(2) != 42)
		return 4;
	var names = FileSystem.readDirectory("/projects/demo");
	if (names.length != 2 || names[0] != "assets" || names[1] != "scene.json" || FileSystem.readDirectory("/missing") != null)
		return 5;
	var metadata = FileSystem.metadata("/projects/demo/scene.json");
	if (metadata == null || metadata.size != 12 || metadata.modified <= 0 || FileSystem.metadata("/missing") != null)
		return 6;
	File.saveContent("/projects/demo/scene.json", "x");
	var rewritten = FileSystem.metadata("/projects/demo/scene.json");
	if (rewritten == null || rewritten.size != 1 || rewritten.modified <= metadata.modified)
		return 7;
	return 0;
}

function failures():Int {
	var missingRead = false,
		missingParent = false,
		directoryWrite = false,
		textBinary = false;
	try
		File.getContent("/missing.txt")
	catch (error:String)
		missingRead = error == "Could not open source file";
	try
		File.saveContent("/no/such/dir/file.txt", "x")
	catch (error:String)
		missingParent = error == "Could not open output file";
	try
		File.saveContent("/projects", "x")
	catch (error:String)
		directoryWrite = true;
	try
		File.getContent("/projects/demo/assets/blob.bin")
	catch (error:String)
		textBinary = true;
	if (!missingRead || !missingParent || !directoryWrite || !textBinary)
		return 8;
	// Sys.createDir is mkdir: no missing parents, and an existing path fails.
	if (Sys.createDir("/a/b", 493) || !Sys.createDir("/a", 493) || Sys.createDir("/a", 493) || !Sys.createDir("/a/b", 493))
		return 9;
	if (Sys.removeDir("/a") || !Sys.removeDir("/a/b") || !Sys.removeDir("/a") || Sys.exists("/a"))
		return 10;
	return 0;
}

function moves():Int {
	FileSystem.rename("/projects/demo", "/projects/renamed");
	if (FileSystem.exists("/projects/demo")
		|| File.getContent("/projects/renamed/scene.json") != "x"
		|| File.getBytes("/projects/renamed/assets/blob.bin").get(2) != 42)
		return 16;
	var rejected = false;
	try
		FileSystem.rename("/projects/renamed", "/projects/renamed/inside")
	catch (error:String)
		rejected = true;
	if (!rejected || !Sys.rename("/projects/renamed/scene.json", "/projects/scene.json") || Sys.exists("/projects/renamed/scene.json"))
		return 17;
	if (!Sys.setCwd("/projects")
		|| Sys.getCwd() != "/projects/"
		|| File.getContent("scene.json") != "x"
		|| Sys.setCwd("/missing"))
		return 18;
	Sys.setCwd("/");
	FileSystem.deleteFile("/projects/scene.json");
	FileSystem.deleteFile("/projects/renamed/assets/blob.bin");
	FileSystem.deleteDirectory("/projects/renamed/assets");
	FileSystem.deleteDirectory("/projects/renamed");
	if (FileSystem.exists("/projects/renamed") || FileSystem.readDirectory("/projects").length != 0)
		return 19;
	return 0;
}

function atomic():Int {
	AtomicFile.write("/settings.json", "one");
	AtomicFile.write("/settings.json", "two");
	var refused = false;
	try
		AtomicFile.create("/settings.json", "three")
	catch (error:String)
		refused = true;
	var orphan = false;
	try
		AtomicFile.write("/missing/settings.json", "x")
	catch (error:String)
		orphan = true;
	return refused && orphan && File.getContent("/settings.json") == "two" ? 0 : 32;
}

function numbers():Int {
	var huge = haxe.Int64.fromFloat(1e300),
		tiny = haxe.Int64.fromFloat(-1e300),
		nan = haxe.Int64.fromFloat(Math.NaN);
	return haxe.Int64.compare(huge, haxe.Int64.make(0x7fffffff, -1)) == 0
		&& haxe.Int64.compare(tiny, haxe.Int64.make(-2147483647 - 1, 0)) == 0
		&& haxe.Int64.compare(nan, haxe.Int64.ofInt(0)) == 0 ? 0 : 64;
}

function gc():Int {
	hl.Gc.enable(false);
	hl.Gc.enable(true);
	hl.Gc.major();
	hl.Gc.setMarkThreshold(0.5);
	return hl.Gc.markThreshold() == 0.5 && hl.Gc.heapBytes() == 0.0 && hl.Gc.allocatedSinceCollection() == 0.0 ? 0 : 128;
}

function main():Int {
	var result = host() | files() | failures() | moves() | atomic() | numbers() | gc();
	return result == 0 ? 42 : result;
}
