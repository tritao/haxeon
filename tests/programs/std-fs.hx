import haxe.io.Bytes;
import std.fs.FileError;
import std.fs.Files;
import std.fs.Path;

// std.fs answers each operation with a Result whose Err names the failure, on the runtime's natives and on Wasm's
// in-memory filesystem alike: reads and writes, create and atomic writes, metadata, listings, directories made with
// their parents, remove (succeeds on nothing) against delete (NotFound), whole trees, renames and copies.

function failure<T>(result:Result<T, FileError>):String
	return switch result {
		case Ok(_): "ok";
		case Err(error): error.describe();
	}

function paths():Int {
	var root:Path = "a//b/./c/";
	if (root.toString() != "a/b/c" || root.name() != "c" || root.parent().toString() != "a/b")
		return 1;
	if (Path.of("").toString() != "." || Path.of("/").parent() != null || Path.of("c").parent().toString() != ".")
		return 2;
	if (Path.of("/x").parent().toString() != "/" || Path.of("a/../b").toString() != "a/../b")
		return 3;
	if (root.join("d.txt").toString() != "a/b/c/d.txt" || root.join("/abs").toString() != "/abs"
		|| Path.of(".").join("e").toString() != "e")
		return 4;
	if (Path.of("x/archive.tar.gz").extension() != "gz" || Path.of(".hidden").extension() != ""
		|| !Path.of("/x").isAbsolute() || Path.of("x").isAbsolute())
		return 5;
	return 0;
}

function files(base:Path):Int {
	var file = base.join("notes.txt");
	if (failure(Files.writeText(file, "first")) != "ok" || failure(Files.appendText(file, " second")) != "ok")
		return 10;
	if (Files.readText(file).unwrapOr("") != "first second")
		return 11;
	var described = Files.metadata(file).unwrap();
	if (!described.isFile() || described.size != 12 || described.modified <= 0)
		return 12;
	if (failure(Files.create(file, Bytes.ofString("again"))) != "already exists"
		|| Files.readText(file).unwrapOr("") != "first second")
		return 13;
	if (failure(Files.writeAtomic(file, Bytes.ofString("atomic"))) != "ok"
		|| Files.readText(file).unwrapOr("") != "atomic")
		return 14;
	if (failure(Files.read(base.join("missing.txt"))) != "not found"
		|| failure(Files.read(base.join("missing/inner.txt"))) != "not found")
		return 15;
	if (failure(Files.read(base)) != "is a directory" || failure(Files.writeText(base, "x")) != "is a directory")
		return 16;
	if (failure(Files.writeText(file.join("inner.txt"), "x")) != "not a directory")
		return 17;
	if (failure(Files.copy(file, base.join("copy.txt"))) != "ok"
		|| Files.readText(base.join("copy.txt")).unwrapOr("") != "atomic")
		return 18;
	return 0;
}

function directories(base:Path):Int {
	var deep = base.join("tree/one/two");
	if (failure(Files.createDirectory(deep)) != "ok" || failure(Files.createDirectory(deep)) != "ok")
		return 20;
	if (!Files.metadata(deep).unwrap().isDirectory())
		return 21;
	Files.writeText(deep.join("leaf.txt"), "leaf").unwrap();
	Files.writeText(base.join("tree/top.txt"), "top").unwrap();
	if (failure(Files.createDirectory(base.join("tree/top.txt"))) != "already exists")
		return 22;
	var names = [for (entry in Files.list(base.join("tree")).unwrap()) entry.name + ":" + entry.kind];
	names.sort(Reflect.compare);
	if (names.join(",") != "one:Directory,top.txt:File")
		return 23;
	if (failure(Files.list(base.join("tree/top.txt"))) != "not a directory"
		|| failure(Files.list(base.join("none"))) != "not found")
		return 24;
	if (failure(Files.remove(base.join("tree/one"))) != "directory not empty")
		return 25;
	if (failure(Files.remove(base.join("tree/none"))) != "ok"
		|| failure(Files.delete(base.join("tree/none"))) != "not found")
		return 26;
	if (failure(Files.rename(base.join("tree/top.txt"), base.join("tree/one/top.txt"))) != "ok"
		|| Files.readText(base.join("tree/one/top.txt")).unwrapOr("") != "top")
		return 27;
	if (failure(Files.rename(base.join("tree/none"), base.join("tree/other"))) != "not found")
		return 28;
	if (failure(Files.removeTree(base.join("tree"))) != "ok"
		|| failure(Files.metadata(base.join("tree"))) != "not found")
		return 29;
	if (failure(Files.removeTree(base.join("tree"))) != "ok")
		return 30;
	return 0;
}

function main():Int {
	var base:Path = "out/std-fs";
	Files.removeTree(base).unwrap();
	Files.createDirectory(base).unwrap();
	var failed = paths();
	if (failed == 0)
		failed = files(base);
	if (failed == 0)
		failed = directories(base);
	Files.removeTree(base).unwrap();
	return failed == 0 ? 42 : failed;
}
