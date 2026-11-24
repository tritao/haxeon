import haxe.io.Path;

function main():Int {
	var checks = [
		Path.extension("a/b.c/file.tar.gz") == "gz",
		Path.extension("a/b.c/file") == "",
		Path.extension("C:\\dir.x\\name") == "",
		Path.withoutExtension("a/b.c/file.hl") == "a/b.c/file",
		Path.withoutExtension("a/b.c/file") == "a/b.c/file",
		Path.withExtension("out/app.hl", "functions") == "out/app.functions",
		Path.withExtension("out/app", "hl") == "out/app.hl",
		Path.addTrailingSlash("") == "/",
		Path.addTrailingSlash("a/b") == "a/b/",
		Path.addTrailingSlash("a/b/") == "a/b/",
		Path.addTrailingSlash("C:\\a") == "C:\\a\\"
	];
	for (index in 0...checks.length)
		if (!checks[index])
			return 100 + index;
	return 42;
}
