import sys.FileSystem;
import sys.io.File;

/** Every name in `StdlibNames` names a declaration of the standard library, so moving one without the table fails here. */
class StdlibNamesMain {
	static inline final TABLE = "src/compiler/core/StdlibNames.hx";
	static inline final ROOT = "stdlib";


	static function main():Void {
		var names = [], table = File.getContent(TABLE), pattern = ~/static inline final [A-Z0-9_]+ = "([^"]+)";/;
		while (pattern.match(table)) {
			names.push(pattern.matched(1));
			table = pattern.matchedRight();
		}
		if (names.length == 0)
			fail('$TABLE declares no names');
		var missing = [for (name in names) if (!declared(name)) name];
		if (missing.length > 0)
			fail('Names in $TABLE that the standard library does not declare: ${missing.join(", ")}');
	}

	static function declared(name:String):Bool {
		if (StringTools.endsWith(name, "."))
			return FileSystem.isDirectory('$ROOT/${name.substr(0, name.length - 1).split(".").join("/")}');
		if (typeSource(name) != null)
			return true;
		var dot = name.lastIndexOf(".");
		if (dot < 0)
			return false;
		var owner = typeSource(name.substr(0, dot));
		if (owner == null)
			return false;
		return new EReg('\\b(function|var|final)\\s+${name.substr(dot + 1)}\\b', "").match(owner);
	}

	/** The source of the module declaring the type `path`: its own module, or one of its package's modules. */
	static function typeSource(path:String):Null<String> {
		var parts = path.split("."), file = '$ROOT/${parts.join("/")}.hx';
		if (FileSystem.exists(file))
			return File.getContent(file);
		var type = parts.pop(), directory = parts.length == 0 ? ROOT : '$ROOT/${parts.join("/")}';
		if (!FileSystem.isDirectory(directory))
			return null;
		var declaration = new EReg('\\b(class|interface|enum|abstract|typedef)\\s+$type\\b', "");
		for (entry in FileSystem.readDirectory(directory))
			if (StringTools.endsWith(entry, ".hx")) {
				var source = File.getContent('$directory/$entry');
				if (declaration.match(source))
					return source;
			}
		return null;
	}

	static function fail(message:String):Void {
		Sys.println(message);
		Sys.exit(1);
	}
}
