import haxe.io.Bytes;
import std.fs.EntryKind;
import std.fs.FileError;
import std.fs.Files;
import std.fs.Root;

// A std.fs.Root confines every operation to its directory: `..` and absolute paths fail with EscapesRoot, and so does a
// symbolic link that leads out (made with `ln -s` where the system has it), while one that stays inside is followed.
// On Wasm a root is a directory of the in-memory filesystem.

function failure<T>(result:Result<T, FileError>):String
	return switch result {
		case Ok(_): "ok";
		case Err(error): error.describe();
	}

function opening():Int {
	if (failure(Root.open("out/std-fs-root/missing")) != "not found"
		|| failure(Root.open("out/std-fs-root/secret.txt")) != "not a directory")
		return 1;
	return 0;
}

function confined(root:Root):Int {
	if (failure(root.writeText("notes.txt", "inside")) != "ok" || root.readText("notes.txt").unwrapOr("") != "inside")
		return 10;
	if (failure(root.read("../secret.txt")) != "escapes the root"
		|| failure(root.read("/etc/hosts")) != "escapes the root"
		|| failure(root.read("sub/../notes.txt")) != "escapes the root")
		return 11;
	if (failure(root.writeText("../planted.txt", "x")) != "escapes the root"
		|| Files.metadata("out/std-fs-root/planted.txt").isOk())
		return 12;
	if (failure(root.createDirectory("deep/er")) != "ok" || failure(root.createDirectory(".")) != "ok")
		return 13;
	if (failure(root.appendText("deep/er/log.txt", "a")) != "ok"
		|| failure(root.appendText("deep/er/log.txt", "b")) != "ok"
		|| root.readText("deep/er/log.txt").unwrapOr("") != "ab")
		return 14;
	if (failure(root.create("notes.txt", Bytes.ofString("again"))) != "already exists"
		|| failure(root.writeAtomic("notes.txt", Bytes.ofString("atomic"))) != "ok"
		|| root.readText("notes.txt").unwrapOr("") != "atomic")
		return 15;
	var names = [for (entry in root.list(".").unwrap()) entry.name + ":" + entry.kind];
	names.sort(Reflect.compare);
	if (names.join(",") != "deep:Directory,notes.txt:File" || !root.metadata(".").unwrap().isDirectory())
		return 16;
	if (failure(root.rename("notes.txt", "deep/notes.txt")) != "ok"
		|| failure(root.rename("deep/notes.txt", "../notes.txt")) != "escapes the root")
		return 17;
	if (failure(root.copy("deep/notes.txt", "copy.txt")) != "ok" || root.readText("copy.txt").unwrapOr("") != "atomic")
		return 18;
	if (failure(root.remove(".")) != "permission denied" || failure(root.delete("none")) != "not found"
		|| failure(root.remove("none")) != "ok")
		return 19;
	if (failure(root.removeTree("deep")) != "ok" || failure(root.metadata("deep")) != "not found")
		return 20;
	return 0;
}

function linked(root:Root):Int {
	#if !wasm
	if (Sys.systemName() == "Windows")
		return 0;
	var base = "out/std-fs-root/inside";
	if (Sys.command("ln", ["-s", "../secret.txt", '$base/out-link']) != 0
		|| Sys.command("ln", ["-s", "..", '$base/up']) != 0
		|| Sys.command("ln", ["-s", "copy.txt", '$base/in-link']) != 0)
		return 30;
	if (failure(root.read("out-link")) != "escapes the root"
		|| failure(root.writeText("out-link", "x")) != "escapes the root"
		|| failure(root.metadata("out-link")) != "escapes the root")
		return 31;
	if (root.linkMetadata("out-link").unwrap().kind != SymbolicLink)
		return 32;
	if (failure(root.read("up/secret.txt")) != "escapes the root"
		|| failure(root.writeText("up/planted.txt", "x")) != "escapes the root"
		|| failure(root.list("up")) != "escapes the root"
		|| failure(root.delete("up/secret.txt")) != "escapes the root")
		return 33;
	if (root.readText("in-link").unwrapOr("") != "atomic")
		return 34;
	// Removing a tree removes its links, not what they point to.
	if (failure(root.removeTree(".")) != "permission denied")
		return 35;
	for (name in ["out-link", "up", "in-link"])
		if (failure(root.delete(name)) != "ok")
			return 36;
	if (Files.readText("out/std-fs-root/secret.txt").unwrapOr("") != "secret")
		return 37;
	#end
	return 0;
}

function main():Int {
	Files.removeTree("out/std-fs-root").unwrap();
	Files.createDirectory("out/std-fs-root/inside").unwrap();
	Files.writeText("out/std-fs-root/secret.txt", "secret").unwrap();
	var failed = opening();
	var root = Root.open("out/std-fs-root/inside").unwrap();
	if (failed == 0)
		failed = confined(root);
	if (failed == 0)
		failed = linked(root);
	root.close();
	if (failed == 0) {
		var threw = false;
		try
			_ = root.read("copy.txt")
		catch (error:haxe.Exception)
			threw = true;
		if (!threw || !root.isClosed())
			failed = 40;
	}
	Files.removeTree("out/std-fs-root").unwrap();
	return failed == 0 ? 42 : failed;
}
