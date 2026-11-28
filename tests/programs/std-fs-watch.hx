import std.fs.ChangeKind;
import std.fs.FileError;
import std.fs.Files;
import std.fs.Path;
import std.fs.WatchEvent;
import std.fs.Watcher;

// std.fs.Watcher reports each path added, removed or modified under a watched directory, leaves an excluded subtree
// out, watches a directory created under a recursive one, says why a directory cannot be watched, and wakes from
// another thread. Where the system offers no watching (Wasm), open is Unsupported.

function failure<T>(result:Result<T, FileError>):String
	return switch result {
		case Ok(_): "ok";
		case Err(error): error.describe();
	}

#if !wasm
/** Waits until `seen` holds an event matching `wanted`, for up to five seconds. */
function await(watcher:Watcher, seen:Array<WatchEvent>, wanted:WatchEvent->Bool):Bool {
	var deadline = Sys.time() + 5;
	while (Sys.time() < deadline) {
		for (event in seen)
			if (wanted(event))
				return true;
		for (event in watcher.wait(0.25))
			seen.push(event);
	}
	return false;
}

function changed(path:String, kind:ChangeKind):WatchEvent->Bool
	return event -> switch event {
		case Changed(at, happened): at.toString() == path && happened == kind;
		case Rescan: false;
	};

#end

function main():Int {
	#if wasm
	return Watcher.open().match(Err(Unsupported)) ? 42 : 1;
	#else
	var watcher = switch Watcher.open() {
		case Ok(opened): opened;
		case Err(Unsupported): return 42;
		case Err(error): return 1;
	};
	var base = "out/std-fs-watch";
	Files.removeTree(base).unwrap();
	Files.createDirectory('$base/sub').unwrap();
	Files.createDirectory('$base/skip').unwrap();
	Files.writeText('$base/file.txt', "file").unwrap();
	if (failure(watcher.add('$base/missing', true)) != "not found"
		|| failure(watcher.add('$base/file.txt')) != "not a directory")
		return 2;
	watcher.exclude('$base/skip');
	if (failure(watcher.add(base, true)) != "ok" || failure(watcher.add(base, true)) != "ok")
		return 3;
	var seen:Array<WatchEvent> = [];
	Files.writeText('$base/sub/deep.txt', "deep").unwrap();
	Files.writeText('$base/skip/hidden.txt', "hidden").unwrap();
	Files.delete('$base/file.txt').unwrap();
	if (!await(watcher, seen, changed('$base/sub/deep.txt', Added))
		|| !await(watcher, seen, changed('$base/file.txt', Removed)))
		return 4;
	Files.createDirectory('$base/new').unwrap();
	if (!await(watcher, seen, changed('$base/new', Added)))
		return 5;
	Files.writeText('$base/new/later.txt', "later").unwrap();
	if (!await(watcher, seen, changed('$base/new/later.txt', Added)))
		return 6;
	if (seen.filter(changed('$base/skip/hidden.txt', Added)).length != 0)
		return 7;

	// A wake from another thread ends a wait that would last a minute.
	var started = Sys.time();
	sys.thread.Thread.create(() -> {
		Sys.sleep(0.1);
		watcher.wake();
	});
	_ = watcher.wait(60);
	if (Sys.time() - started > 30)
		return 8;

	if (failure(watcher.remove(base)) != "ok" || failure(watcher.remove(base)) != "not found")
		return 9;
	watcher.close();
	var threw = false;
	try
		_ = watcher.wait(0)
	catch (error:haxe.Exception)
		threw = true;
	Files.removeTree(base).unwrap();
	return threw && watcher.isClosed() ? 42 : 10;
	#end
}
