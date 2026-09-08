function main():Int {
	var cwd = Sys.getCwd();
	var now = Sys.time();
	var systemName = Sys.systemName();
	if (cwd.length == 0
		|| ["Windows", "Mac", "Linux", "BSD", "Unknown"].indexOf(systemName) < 0
		|| !Sys.exists(cwd)
		|| !sys.FileSystem.exists(cwd)
		|| !sys.FileSystem.isDirectory(cwd)
		|| sys.FileSystem.fullPath(".").length == 0
		|| now < 0.0)
		return 0;
	var directory = "out/sys-runtime-é";
	var renamed = "out/sys-runtime-renamed-é";
	var file = "out/sys-runtime-renamed-é/value-ß.txt";
	var bytesFile = "out/sys-runtime-renamed-é/bytes-ç.txt";
	if (Sys.exists(file))
		Sys.delete(file);
	if (Sys.exists(bytesFile))
		Sys.delete(bytesFile);
	if (Sys.exists(directory))
		Sys.removeDir(directory);
	if (Sys.exists(renamed))
		Sys.removeDir(renamed);
	if (!Sys.createDir(directory, 493) || !Sys.rename(directory, renamed))
		return 1;
	sys.io.File.saveContent(file, "42");
	var savedBytes = haxe.io.Bytes.alloc(4);
	savedBytes.set(0, 0);
	savedBytes.set(1, 255);
	savedBytes.set(2, 42);
	savedBytes.set(3, 128);
	sys.io.File.saveBytes(bytesFile, savedBytes);
	var loadedBytes = sys.io.File.getBytes(bytesFile);
	if (!Sys.exists(file)
		|| sys.io.File.getContent(file) != "42"
		|| loadedBytes.length != 4
		|| loadedBytes.get(0) != 0
		|| loadedBytes.get(1) != 255
		|| loadedBytes.get(2) != 42
		|| loadedBytes.get(3) != 128
		|| Sys.readDir(renamed).indexOf("value-ß.txt") < 0)
		return 2;
	if (!Sys.delete(file) || !Sys.delete(bytesFile) || !Sys.removeDir(renamed))
		return 3;
	if (!Sys.setCwd("out"))
		return 4;
	var moved = Sys.getCwd();
	if (!Sys.setCwd(cwd) || moved == cwd)
		return 5;
	if (!Sys.putEnv("HAXEON_SYS_É", "válue-ß") || Sys.getEnv("HAXEON_SYS_É") != "válue-ß")
		return 6;
	if (Sys.command("test xé = xé") != 0)
		return 7;
	var fsDirectory = "out/filesystem-runtime-é";
	var fsRenamed = "out/filesystem-runtime-renamed-é";
	var fsFile = fsRenamed + "/value-ß.txt";
	if (sys.FileSystem.exists(fsFile))
		sys.FileSystem.deleteFile(fsFile);
	if (sys.FileSystem.exists(fsDirectory))
		sys.FileSystem.deleteDirectory(fsDirectory);
	if (sys.FileSystem.exists(fsRenamed))
		sys.FileSystem.deleteDirectory(fsRenamed);
	sys.FileSystem.createDirectory(fsDirectory);
	if (!sys.FileSystem.isDirectory(fsDirectory) || sys.FileSystem.absolutePath(fsDirectory).length == 0)
		return 8;
	sys.FileSystem.rename(fsDirectory, fsRenamed);
	sys.io.File.saveContent(fsFile, "filesystem");
	var metadata = sys.FileSystem.metadata(fsFile);
	if (!sys.FileSystem.exists(fsFile)
		|| metadata == null
		|| metadata.size != 10
		|| metadata.modified <= 0
		|| sys.FileSystem.readDirectory(fsRenamed).indexOf("value-ß.txt") < 0)
		return 9;
	sys.FileSystem.deleteFile(fsFile);
	if (sys.FileSystem.metadata(fsFile) != null)
		return 11;
	sys.FileSystem.deleteDirectory(fsRenamed);
	if (sys.FileSystem.exists(fsRenamed))
		return 10;
	var mutex = new sys.thread.Mutex(), threaded = [0];
	sys.thread.Thread.create(function() {
		mutex.acquire();
		threaded[0] = 42;
		mutex.release();
	});
	var attempts = 0;
	while (attempts < 100) {
		mutex.acquire();
		var finished = threaded[0] == 42;
		mutex.release();
		if (finished) break;
		Sys.sleep(0.001);
		attempts++;
	}
	if (threaded[0] != 42)
		return 12;
	Sys.println("PASS: Sys UTF-8 marshalling ✓\n");
	trace("PASS: trace UTF-8 marshalling ✓\n");
	return 42;
}
