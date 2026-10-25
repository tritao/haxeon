import compiler.modules.ModuleSourceLoader;
import compiler.modules.ModuleState;
import sys.FileSystem;
import sys.io.File;

class ModuleSourceLoaderCacheMain {
	static function check(condition:Bool, message:String):Void {
		if (!condition)
			throw message;
	}

	static function remove(path:String):Void {
		if (!FileSystem.exists(path))
			return;
		if (FileSystem.isDirectory(path)) {
			for (entry in FileSystem.readDirectory(path))
				remove(path + "/" + entry);
			FileSystem.deleteDirectory(path);
		} else
			FileSystem.deleteFile(path);
	}

	static function write(path:String, text:String):Void {
		File.saveContent(path, text);
	}

	static function main():Void {
		var root = Sys.getCwd() + "/out/test-module-source-loader-cache";
		remove(root);
		FileSystem.createDirectory(root);
		FileSystem.createDirectory(root + "/pkg");
		FileSystem.createDirectory(root + "/pkg/sub");
		write(root + "/pkg/Foo.hx", "package pkg;\nclass Foo {}\n");
		write(root + "/pkg/Bar.hx", "package pkg;\nclass Bar {}\n");
		write(root + "/pkg/import.hx", "");
		write(root + "/pkg/sub/Deep.hx", "package pkg.sub;\nclass Deep {}\n");
		write(root + "/Top.hx", "class Top {}\n");
		// A file named like a directory must not make `shape.*` resolve as a package.
		write(root + "/shape.hx", "class shape {}\n");

		var loader = new ModuleSourceLoader();
		loader.addRoot(root);
		var modules = new Map<String, ModuleState>();

		// Import resolution probes many distinct names, present and missing, under the same directories.
		for (index in 0...60) {
			check(loader.load("pkg.Missing" + index, modules) == null, "missing module resolved");
			check(loader.load("pkg.sub.Missing" + index, modules) == null, "missing nested module resolved");
			check(loader.load("nothing.Missing" + index, modules) == null, "module under a missing package resolved");
		}
		check(loader.load("pkg.Foo", modules) != null, "pkg.Foo not found");
		check(loader.load("pkg.sub.Deep", modules) != null, "pkg.sub.Deep not found");
		check(loader.load("Top", modules) != null, "Top not found");
		// root, pkg, pkg/sub at most; the missing top-level package `nothing` is found absent from the root listing.
		check(loader.listingReads <= 3, "expected at most one listing per directory, got " + loader.listingReads);

		// Case-exact lookup: an alias differing only in case must not resolve, whatever the filesystem.
		check(loader.load("pkg.foo", modules) == null, "pkg.foo aliased pkg/Foo.hx");
		check(loader.load("Pkg.Foo", modules) == null, "Pkg.Foo aliased pkg/Foo.hx");
		check(loader.load("pkg.sub.deep", modules) == null, "pkg.sub.deep aliased pkg/sub/Deep.hx");
		check(modules.get("pkg.Foo").source.path.indexOf("pkg/Foo.hx") >= 0, "pkg.Foo resolved to the wrong path");
		check(loader.listingReads <= 3, "case probes re-listed directories: " + loader.listingReads);

		// Package loading keeps readDirectory order for module insertion, returns a sorted result, skips import.hx.
		var packageModules = new Map<String, ModuleState>();
		var names = loader.loadPackage("pkg", packageModules);
		check(names.join(",") == "pkg.Bar,pkg.Foo", "loadPackage returned " + names.join(","));
		var inserted = [for (key in packageModules.keys()) key];
		inserted.sort(Reflect.compare);
		check(inserted.join(",") == "pkg.Bar,pkg.Foo", "loadPackage materialized " + inserted.join(","));
		check(loader.loadPackage("pkg.sub", packageModules).join(",") == "pkg.sub.Deep", "nested package not listed");
		check(loader.loadPackage("pkg.none", packageModules).length == 0, "missing package listed modules");
		check(loader.loadPackage("pkg.Foo", packageModules).length == 0, "a module file was treated as a package");
		check(loader.loadPackage("shape", packageModules).length == 0, "a file named like a package was treated as a package");
		check(loader.loadPackage("Pkg", packageModules).length == 0, "package lookup aliased by case");
		check(loader.loadPackage("", packageModules).join(",") == "Top,shape", "root package listing: " + loader.loadPackage("", packageModules).join(","));

		// Freshness: a copy (the next compile request) sees files created after this loader cached its listings.
		write(root + "/pkg/Added.hx", "package pkg;\nclass Added {}\n");
		var next = loader.copy();
		check(next.listingReads == 0, "a copy inherited the listing counter");
		check(next.load("pkg.Added", new Map<String, ModuleState>()) != null, "a new loader missed a file added since the last request");
		check(next.loadPackage("pkg", new Map<String, ModuleState>()).join(",") == "pkg.Added,pkg.Bar,pkg.Foo", "a new loader's package listing was stale");

		remove(root);
		Sys.println("PASS: module source loader lists each directory once per loader, stays case-exact, and re-lists on copy");
	}
}
