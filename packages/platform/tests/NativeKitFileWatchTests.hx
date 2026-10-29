import haxeon.platform.event.EventPump;
import haxeon.platform.FileWatch;
import haxeon.platform.FileWatchEvent;
import nativekit.ffi.NativeKit;
import nativekit.ffi.NativeKitTypes;
import sys.FileSystem;
import sys.io.File;

/** FileWatch on the real backend: readiness, deep changes, exclusions, lost registrations and removal. */
class NativeKitFileWatchTests {
	public static function run(events:EventPump):Bool {
		var capabilities:Capabilities = NativeKit.nk_get_capabilities();
		if (!capabilities.contains(Capabilities.fileWatch()))
			return true;
		var root = temporaryRoot();
		var watch:Null<FileWatch> = null;
		try {
			for (directory in ["a", "a/b", "build", "build/inner", "gone"])
				FileSystem.createDirectory(root + "/" + directory);
			var received:Array<FileWatchEvent> = [];
			watch = FileWatch.create(events, event -> received.push(event));
			watch.exclude(root + "/build");
			watch.add(root, true);
			watch.add(root + "/gone", false);
			await(events, () -> watch.ready, "the recursive registration never became ready");
			if (!any(received, event -> event.match(Ready)))
				throw "no Ready event when the watch became ready";

			File.saveContent(root + "/build/inner/hidden.txt", "hidden");
			File.saveContent(root + "/a/b/deep.txt", "deep");
			await(events, () -> changed(received, root + "/a/b/deep.txt"), "a change deep in the tree was not reported");
			// The excluded change was written first, so it would have arrived before the deep one.
			if (changed(received, root + "/build/inner/hidden.txt"))
				throw "a change in an excluded subtree was reported";

			FileSystem.deleteDirectory(root + "/gone");
			await(events, () -> any(received, event -> switch event {
				case Lost(path): FileWatch.pathKey(path) == FileWatch.pathKey(root + "/gone");
				case _: false;
			}), "a deleted registration was not reported lost");
			if (watch.directories().length != 1)
				throw "a lost registration was kept: " + watch.directories();

			watch.remove(root);
			if (watch.directories().length != 0 || !watch.ready)
				throw "removing the root left registrations";
			watch.dispose();
			watch.dispose();
			if (!watch.isDisposed())
				throw "a disposed watch reports live";
			deleteTree(root);
			return true;
		} catch (error:Dynamic) {
			Sys.println("FAIL: FileWatch: " + error);
			if (watch != null)
				watch.dispose();
			deleteTree(root);
			return false;
		}
	}

	static function any(received:Array<FileWatchEvent>, matches:FileWatchEvent->Bool):Bool {
		for (event in received)
			if (matches(event))
				return true;
		return false;
	}

	static function changed(received:Array<FileWatchEvent>, path:String):Bool {
		var key = FileWatch.pathKey(path);
		return any(received, event -> switch event {
			case Changed(change): FileWatch.pathKey(change.path) == key;
			case _: false;
		});
	}

	static function await(events:EventPump, done:Void->Bool, message:String):Void {
		var deadline = Sys.time() + 5.0;
		while (!done()) {
			if (Sys.time() > deadline)
				throw message;
			events.poll();
			Sys.sleep(0.005);
		}
	}

	static function temporaryRoot():String {
		var base = Sys.getEnv("TMPDIR");
		if (base == null || base.length == 0)
			base = Sys.systemName() == "Windows" ? Sys.getEnv("TEMP") : "/tmp";
		var root = base + "/haxeon-file-watch-" + Std.int(Sys.time() * 1000) + "-" + Std.random(100000);
		FileSystem.createDirectory(root);
		return FileSystem.fullPath(root);
	}

	static function deleteTree(path:String):Void {
		if (!FileSystem.exists(path))
			return;
		if (FileSystem.isDirectory(path)) {
			for (name in FileSystem.readDirectory(path))
				deleteTree(path + "/" + name);
			FileSystem.deleteDirectory(path);
		} else
			FileSystem.deleteFile(path);
	}
}
