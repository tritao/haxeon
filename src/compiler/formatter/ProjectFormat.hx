package compiler.formatter;

import compiler.formatter.FormatConfig.FormatConfigTools;
import haxe.Json;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;

/**
 * The formatting of a source file, from its project: the `format` section of the nearest haxeon.json above it that has one, else the
 * standard style (tabs, 120 columns). `haxeon fmt`, `haxeon lint --fix` and the language server all ask here, so a file formats the
 * same from every tool and editor.
 *
 *   "format": {"indent": "tabs" | "spaces", "indentWidth": 4, "lineWidth": 120}
 *
 * Every key is optional. `indentWidth` is the width of one indentation level: the number of spaces, or the columns a tab counts for
 * when lines are measured. A nested haxeon.json without a `format` section (a package's tests) takes its enclosing project's.
 */
class ProjectFormat {
	static inline final MANIFEST = "haxeon.json";

	/** Directory -> the configuration that applies to files in it, filled as lookups walk up. */
	final cache = new Map<String, FormatConfig>();

	public function new() {}

	public static function standard():FormatConfig
		return FormatConfigTools.make(4, false);

	/** The configuration for the file at `path` (it need not exist, so `<dir>/<stdin>` names a directory's). */
	public function forFile(path:String):FormatConfig {
		var directory = Path.directory(FileSystem.absolutePath(path)), visited = [], config:Null<FormatConfig> = null;
		while (true) {
			var cached = cache.get(directory);
			if (cached != null) {
				config = cached;
				break;
			}
			visited.push(directory);
			var manifest = Path.join([directory, MANIFEST]);
			if (FileSystem.exists(manifest)) {
				config = read(manifest);
				if (config != null)
					break;
			}
			var parent = Path.directory(directory);
			if (parent == directory || parent == "")
				break;
			directory = parent;
		}
		if (config == null)
			config = standard();
		for (seen in visited)
			cache.set(seen, config);
		return config;
	}

	/** The `format` section of a manifest, or null when it has none. Malformed settings are errors, never silently ignored. */
	public static function read(manifest:String):Null<FormatConfig> {
		var raw:Dynamic;
		try
			raw = Json.parse(File.getContent(manifest))
		catch (error:Dynamic)
			throw '$manifest: not valid JSON: $error';
		var section:Dynamic = Reflect.field(raw, "format");
		if (section == null)
			return null;
		return parse(section, manifest);
	}

	public static function parse(section:Dynamic, origin:String):FormatConfig {
		if (section == null || !Reflect.isObject(section) || Std.isOfType(section, String) || Std.isOfType(section, Array))
			throw '$origin: "format" must be an object';
		var spaces = false, indentWidth = 4, lineWidth = 120;
		for (key in Reflect.fields(section)) {
			var value:Dynamic = Reflect.field(section, key);
			switch key {
				case "indent":
					if (value != "tabs" && value != "spaces")
						throw '$origin: format.indent must be "tabs" or "spaces"';
					spaces = value == "spaces";
				case "indentWidth":
					indentWidth = positive(value, origin, key);
				case "lineWidth":
					lineWidth = positive(value, origin, key);
				case _:
					throw '$origin: unknown format setting "$key" (known: indent, indentWidth, lineWidth)';
			}
		}
		var config = FormatConfigTools.make(indentWidth, spaces);
		config.lineWidth = lineWidth;
		return config;
	}

	static function positive(value:Dynamic, origin:String, key:String):Int {
		if (!Std.isOfType(value, Int) || (value : Int) < 1)
			throw '$origin: format.$key must be a whole number of at least 1';
		return value;
	}
}
