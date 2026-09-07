function main():Int {
	var cwd = Sys.getCwd();
	var now = Sys.time();
	if (cwd.length == 0
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
	sys.io.File.saveBytes(bytesFile, haxe.io.Bytes.ofString("bytes"));
	if (!Sys.exists(file)
		|| sys.io.File.getContent(file) != "42"
		|| sys.io.File.getContent(bytesFile) != "bytes"
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
	Sys.println("PASS: Sys UTF-8 marshalling ✓\n");
	trace("PASS: trace UTF-8 marshalling ✓\n");
	return 42;
}
