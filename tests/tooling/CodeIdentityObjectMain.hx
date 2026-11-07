import compiler.tools.CompilerArguments;
import compiler.tools.CompilerDriver;
import compiler.tools.CompilerSession;
import sys.FileSystem;
import sys.io.File;
import sys.io.Process;

/**
 * `haxeon.build.CodeIdentity.ofObject`: the identity of the module defining an object's concrete class. A subclass instance
 * gives its own module's identity, which changes when the subclass's or its base class's source changes and not when an
 * unrelated module changes; generic instantiations give their class's module; private classes, closures, records, null and
 * classes outside the program give null.
 *
 * Module graph: Main -> Base, Sub1, Sub2, Box, Hidden, Other; Sub1 -> Base; Sub2 -> Base.
 */
class CodeIdentityObjectMain {
	static var root = "";
	static var checks = 0;
	static final all = ["Main", "Base", "Sub1", "Sub2", "Box", "Hidden", "Other"];

	static function sources(edits:Map<String, String>):Map<String, String> {
		var files = [
			"Main" => 'import haxeon.build.CodeIdentity;
import ci.*;
class Main {
	static function main():Int {
		var objects:Map<String, Dynamic> = [
			"Base" => new Base(), "Sub1" => new Sub1(), "Sub2" => new Sub2(), "Box" => new Box<Int>(1), "Other" => new Other(),
			"Hidden" => Hidden.make()
		];
		for (name in ["Base", "Sub1", "Sub2", "Box", "Hidden", "Other"])
			Sys.println(name + "=" + CodeIdentity.ofModule("ci." + name));
		for (name => object in objects) {
			Sys.println("object-" + name + "=" + CodeIdentity.ofObject(object));
			Sys.println("class-" + name + "=" + CodeIdentity.className(object));
		}
		var text:Dynamic = "text";
		var closure:Dynamic = () -> 1;
		var record:Dynamic = {a: 1};
		Sys.println("closure=" + CodeIdentity.ofObject(closure));
		Sys.println("record=" + CodeIdentity.ofObject(record));
		Sys.println("null=" + CodeIdentity.ofObject(null));
		Sys.println("string=" + CodeIdentity.ofObject(text));
		Sys.println("array=" + CodeIdentity.ofObject([1, 2]));
		Sys.println("libs=" + CodeIdentity.loadedLibraries("libhl"));
		Sys.println("libs-again=" + CodeIdentity.loadedLibraries("libhl"));
		Sys.println("libs-none=" + CodeIdentity.loadedLibraries("libNoSuchLibraryAnywhere"));
		return 0;
	}
}',
			"Base" => "package ci;\nclass Base { public function new() {} public function tag():String return \"base\"; }",
			"Sub1" => "package ci;\nclass Sub1 extends Base { public function new() super(); override public function tag():String return \"one\"; }",
			"Sub2" => "package ci;\nclass Sub2 extends Base { public function new() super(); override public function tag():String return \"two\"; }",
			"Box" => "package ci;\nclass Box<T> { public final value:T; public function new(value:T) this.value = value; }",
			"Hidden" => "package ci;\nclass Hidden { public static function make():Dynamic return new Secret(); }\nprivate class Secret { public function new() {} }",
			"Other" => "package ci;\nclass Other { public function new() {} }"
		];
		for (name => text in edits)
			files.set(name, text);
		return files;
	}

	static function path(name:String):String
		return root + (name == "Main" ? "/" : "/ci/") + name + ".hx";

	static function write(files:Map<String, String>):Void
		for (name => text in files)
			File.saveContent(path(name), text);

	static function build(session:CompilerSession, tag:String):Map<String, String> {
		var output = root + "/" + tag + ".hl";
		var args = ["--target=hl", "--entry=Main", "--root=" + root, "--output=" + output];
		CompilerDriver.compile(CompilerArguments.parse(args.concat([for (name in all) path(name)])), _ -> {}, session);
		var process = new Process(Sys.getEnv("HAXEON_HASHLINK_DIR") + "/hl", [output]);
		var text = process.stdout.readAll().toString();
		var code = process.exitCode();
		process.close();
		expect(code == 0, '$tag: the program exited with $code: $text');
		var values = new Map<String, String>();
		for (line in text.split("\n")) {
			var cut = line.indexOf("=");
			if (cut > 0)
				values.set(line.substr(0, cut), line.substr(cut + 1));
		}
		return values;
	}

	/** The names among `all` whose object identity differs. */
	static function changed(before:Map<String, String>, after:Map<String, String>):String
		return [for (name in all) if (before.get("object-" + name) != after.get("object-" + name)) name].join(",");

	static function main():Void {
		root = FileSystem.fullPath(".") + "/out/code-identity-object-test-" + Std.random(0x3fffffff);
		FileSystem.createDirectory(root);
		FileSystem.createDirectory(root + "/ci");
		var base = sources([]);
		write(base);
		var session = new CompilerSession();
		var first = build(session, "first");
				for (name in ["Base", "Sub1", "Sub2", "Box", "Other"]) {
			var module = first.get(name);
			expect(module != null && module.length == 32, 'identity of module $name: $module');
			// A class is identified by its module; a private class and a generic instantiation by the enclosing module.
			expect(first.get("object-" + name) == module, 'ofObject of $name is the module identity: ${first.get("object-" + name)} vs $module');
		}
		expect(first.get("object-Hidden") == "null", "a private class has no identity: " + first.get("object-Hidden"));
		expect(first.get("class-Hidden") == "ci.Secret", "and the runtime names it by package and class, not module: " + first.get("class-Hidden"));
		expect(first.get("class-Box") == "ci.Box" || first.get("class-Box") == "ci.Box<Int>", "a generic instantiation is named by its class: " + first.get("class-Box"));
		expect(first.get("object-Sub1") != first.get("object-Sub2") && first.get("object-Sub1") != first.get("object-Base"),
			"each class has its own identity");
		expect(first.get("closure") == "null" && first.get("record") == "null" && first.get("null") == "null", "closures, records and null have none");
		expect(first.get("string") == "null" && first.get("array") == "null", "runtime classes outside the program have none");

		// Loaded libraries are fingerprinted by name and size (HashLink itself is always loaded), unknown prefixes give null.
		if (Sys.systemName() == "Linux") {
			expect(first.get("libs") != "null" && first.get("libs").length == 64, "the loaded HashLink library has a fingerprint: " + first.get("libs"));
			expect(first.get("libs") == first.get("libs-again"), "and it is stable");
		}
		expect(first.get("libs-none") == "null", "an unknown library prefix has none");

		// A subclass edit changes the subclass only.
		write(sources(["Sub1" => "package ci;\nclass Sub1 extends Base { public function new() super(); override public function tag():String return \"uno\"; }"]));
		var editedSub = build(session, "sub");
		expect(changed(first, editedSub) == "Sub1", "editing Sub1 changed " + changed(first, editedSub));
		write(base);
		build(session, "sub-back");

		// A base class edit changes the base and every subclass, and not the unrelated ones.
		write(sources(["Base" => "package ci;\nclass Base { public function new() {} public function tag():String return \"root\"; }"]));
		var editedBase = build(session, "base");
		expect(changed(first, editedBase) == "Base,Sub1,Sub2", "editing Base changed " + changed(first, editedBase));
		write(base);
		var back = build(session, "base-back");
		expect(changed(first, back) == "", "editing back restores the identities: " + changed(first, back));

		// An unrelated module changes only itself.
		write(sources(["Other" => "package ci;\nclass Other { public function new() {} public var x:Int = 1; }"]));
		var editedOther = build(session, "other");
		expect(changed(first, editedOther) == "Other", "editing Other changed " + changed(first, editedOther));

		// A generic class follows its module.
		write(sources(["Box" => "package ci;\nclass Box<T> { public final value:T; public function new(value:T) this.value = value; public function get():T return value; }"]));
		var editedBox = build(session, "box");
		expect(changed(first, editedBox) == "Box", "editing the generic class changed " + changed(first, editedBox));

		// Incremental and clean builds agree.
		write(base);
		var incremental = build(session, "final");
		var clean = build(new CompilerSession(), "clean");
		expect(changed(incremental, clean) == "", "incremental versus clean build: " + changed(incremental, clean));
		deleteTree(root);
		Sys.println("PASS: object code identities (" + checks + " checks)");
	}

	static function deleteTree(path:String):Void {
		for (entry in FileSystem.readDirectory(path)) {
			var child = path + "/" + entry;
			if (FileSystem.isDirectory(child))
				deleteTree(child);
			else
				FileSystem.deleteFile(child);
		}
		FileSystem.deleteDirectory(path);
	}

	static function expect(condition:Bool, message:String):Void {
		if (!condition)
			throw message;
		checks++;
	}
}
