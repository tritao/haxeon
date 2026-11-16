import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;

/**
 * The compiler keeps no state in statics that one compile could leave for the next, or two compiles could share: a compile server runs
 * one compile after another in one process. Every static that can change, in `src/compiler`, is either moved into the compile's own
 * objects or says why it may be shared with `@:processWide("reason")` (a cache of something that cannot change, an identity marker, a
 * diagnostic count), or `@:threadScoped("reason")` for one a run sets and clears on its own thread. A static that can change is a `static
 * var`, or a `static final` that starts as an empty collection or a new map, array, buffer or lock; a constant table with contents
 * is not one.
 */
class CompilerStaticsMain {
	static final declaration =
		~/^\s*(@:[A-Za-z]+(\("[^"]*"\))?\s+)*((public|private|override)\s+)*static\s+((public|private)\s+)*(inline\s+)?(var|final)\s+([A-Za-z_][A-Za-z0-9_]*)/;
	static final emptyCollection = ~/=\s*\[\s*\]\s*;/;
	static final newContainer =
		~/=\s*new\s+([A-Za-z_][A-Za-z0-9_.]*\.)?(Map|StringMap|IntMap|ObjectMap|EnumValueMap|Array|List|StringBuf|BytesBuffer|Tls|Mutex|Lock|Deque)\b/;
	static final reason = ~/@:(processWide|threadScoped)\("[^"]+"\)/;

	static function main():Void {
		var failures:Array<String> = [], checked = 0;
		for (path in sources("src/compiler")) {
			var lines = File.getContent(path).split("\n");
			for (index in 0...lines.length) {
				var line = lines[index];
				if (!declaration.match(line) || declaration.matched(7) != null)
					continue;
				var kind = declaration.matched(8), name = declaration.matched(9);
				if (kind == "final" && !emptyCollection.match(line) && !newContainer.match(line))
					continue;
				checked++;
				if (!annotated(lines, index))
					failures.push('$path:${index + 1}: static $kind $name can keep state from one compile for the next: move it into the '
						+ 'compile\'s own objects, or say why it may be shared with @:processWide("reason")');
			}
		}
		if (failures.length > 0) {
			Sys.println(failures.join("\n"));
			throw '${failures.length} compiler statics can keep state across compiles without saying why';
		}
		Sys.println('PASS: every one of the $checked compiler statics that can change is process-wide by design, and says why');
	}

	/** Whether the declaration on `lines[index]`, or the metadata lines just above it, gives a reason. */
	static function annotated(lines:Array<String>, index:Int):Bool {
		if (reason.match(lines[index]))
			return true;
		var above = index - 1;
		while (above >= 0 && StringTools.startsWith(StringTools.trim(lines[above]), "@:")) {
			if (reason.match(lines[above]))
				return true;
			above--;
		}
		return false;
	}

	static function sources(directory:String):Array<String> {
		var result:Array<String> = [];
		var names = FileSystem.readDirectory(directory);
		names.sort(Reflect.compare);
		for (name in names) {
			var path = Path.join([directory, name]);
			if (FileSystem.isDirectory(path))
				result = result.concat(sources(path));
			else if (StringTools.endsWith(name, ".hx"))
				result.push(path);
		}
		return result;
	}
}
