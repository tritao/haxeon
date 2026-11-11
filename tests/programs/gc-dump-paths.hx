// hl.Gc.censusDump and hl.Gc.dump write the file their String argument names, exactly. A path handed to a native as a C string
// needs a NUL terminator; without one the file was written as "census.json!".
import sys.FileSystem;

class Box {
	public final value:Int;

	public function new(value:Int)
		this.value = value;
}

function clear(directory:String):Void {
	if (!FileSystem.exists(directory)) {
		FileSystem.createDirectory(directory);
		return;
	}
	for (name in FileSystem.readDirectory(directory))
		FileSystem.deleteFile(directory + "/" + name);
}

function sizeOf(path:String):Int {
	var metadata = FileSystem.metadata(path);
	return metadata == null ? -1 : metadata.size;
}

function main():Int {
	var directory = "out/gc-dump-paths-é";
	clear(directory);
	hl.Gc.censusStart(0);
	var kept = [for (i in 0...100) new Box(i)];
	hl.Gc.censusStop();
	hl.Gc.censusDump(directory + "/census.json");
	hl.Gc.dump(directory + "/heap-é.dump");
	var names = FileSystem.readDirectory(directory);
	names.sort(function(left, right) return left < right ? -1 : left > right ? 1 : 0);
	var exact = names.length == 2 && names[0] == "census.json" && names[1] == "heap-é.dump";
	var written = exact && sizeOf(directory + "/census.json") > 0 && sizeOf(directory + "/heap-é.dump") > 0;
	clear(directory);
	FileSystem.deleteDirectory(directory);
	return written && kept.length == 100 ? 42 : exact ? 2 : 1;
}
