package compiler.ffi;

import compiler.Source.SourceFile;
import compiler.Source.SourceSpan;
import sys.FileSystem;
import sys.io.File;

/** Small AST and source-location helpers shared by language importers. */
class ClangAstTools {
	static final sourceFiles:Map<String, SourceFile> = [];

	public static function field(value:Dynamic, name:String):Dynamic
		return value == null ? null : Reflect.field(value, name);

	public static function children(node:Dynamic):Array<Dynamic> {
		var value:Array<Dynamic> = field(node, "inner");
		return value == null ? [] : value;
	}

	public static function updateFile(node:Dynamic, currentFile:String):String {
		var path = locationPath(node);
		if (path != null)
			currentFile = FileSystem.fullPath(path);
		Reflect.setField(node, "_hxiFile", currentFile);
		return currentFile;
	}

	public static function locationPath(node:Dynamic):Null<String> {
		var location:Dynamic = field(node, "loc"),
			range:Dynamic = field(node, "range"),
			begin:Dynamic = field(range, "begin"),
			expansion:Dynamic = field(begin, "expansionLoc"),
			path:String = field(expansion, "file");
		if (path != null)
			return path;
		path = field(location, "file");
		if (path != null)
			return path;
		var spelling:Dynamic = field(begin, "spellingLoc");
		path = field(spelling, "file");
		return path == null ? field(begin, "file") : path;
	}

	public static function sourceSpan(node:Dynamic, fallback:String):SourceSpan {
		var file:String = field(node, "_hxiFile");
		if (file == null)
			file = fallback;
		var source = sourceFile(file),
			range:Dynamic = field(node, "range"),
			begin:Dynamic = field(range, "begin"),
			end:Dynamic = field(range, "end"),
			start:Dynamic = field(begin, "offset"),
			finish:Dynamic = field(end, "offset"),
			tokenLength:Dynamic = field(end, "tokLen");
		if (start == null)
			start = field(field(node, "loc"), "offset");
		if (finish == null)
			finish = start;
		if (start == null)
			start = 0;
		if (finish == null)
			finish = start;
		finish += tokenLength == null ? 1 : tokenLength;
		var first = Std.int(Math.max(0, Math.min(source.bytes.length, start))),
			last = Std.int(Math.max(first, Math.min(source.bytes.length, finish)));
		return source.span(first, last);
	}

	public static function sourceText(node:Dynamic, fallback:String):String {
		var span = sourceSpan(node, fallback);
		return span.file.slice(span.start, span.end);
	}

	/** Returns whether Clang attached the requested source annotation to a declaration. */
	public static function hasAnnotation(node:Dynamic, expected:String, ?fallbackFile:String):Bool {
		var file:String = field(node, "_hxiFile");
		if (file == null)
			file = locationPath(node);
		if (file == null)
			file = fallbackFile;
		if (file == null || !FileSystem.exists(file))
			return false;
		for (child in children(node)) {
			if (field(child, "kind") != "AnnotateAttr")
				continue;
			var range:Dynamic = field(child, "range"),
				begin:Dynamic = field(range, "begin"),
				end:Dynamic = field(range, "end"),
				spellingBegin:Dynamic = field(begin, "spellingLoc"),
				spellingEnd:Dynamic = field(end, "spellingLoc");
			if (spellingBegin == null)
				spellingBegin = begin;
			if (spellingEnd == null)
				spellingEnd = end;
			if (sourceRange(file, spellingBegin, spellingEnd).indexOf(expected) >= 0)
				return true;
		}
		return false;
	}

	public static function isUserDeclaration(node:Dynamic, roots:Array<String>, currentFile:String):Bool {
		var location:Dynamic = field(node, "loc");
		if (location == null)
			return false;
		var spellingFile = spellingLocationPath(node);
		if (spellingFile != null)
			currentFile = FileSystem.fullPath(spellingFile);
		// Clang omits loc.file for declarations from an included file and
		// records that provenance in includedFrom. In that case the inherited
		// currentFile is not reliable enough to classify the declaration as user
		// source; exclude it conservatively instead of importing libstdc++ AST.
		if (spellingFile == null && locationPath(node) == null && field(location, "includedFrom") != null)
			return false;
		var key = pathKey(currentFile);
		for (root in roots)
			if (key == pathKey(root) || StringTools.startsWith(key, pathKey(root) + "/"))
				return true;
		return false;
	}

	/** Checks a declaration's spelling file, ignoring macro expansion provenance. */
	public static function isSpelledInRoots(node:Dynamic, roots:Array<String>, currentFile:String):Bool {
		var spellingFile = spellingLocationPath(node);
		if (spellingFile == null)
			return isUserDeclaration(node, roots, currentFile);
		var key = pathKey(FileSystem.fullPath(spellingFile));
		for (root in roots)
			if (key == pathKey(root) || StringTools.startsWith(key, pathKey(root) + "/"))
				return true;
		return false;
	}

	static function spellingLocationPath(node:Dynamic):Null<String> {
		var location:Dynamic = field(node, "loc"),
			range:Dynamic = field(node, "range"),
			begin:Dynamic = field(range, "begin"),
			spelling:Dynamic = field(begin, "spellingLoc"),
			path:String = field(spelling, "file");
		if (path != null)
			return path;
		spelling = field(location, "spellingLoc");
		path = field(spelling, "file");
		return path == null ? field(location, "file") : path;
	}

	public static function declarationLocation(node:Dynamic):String {
		var location:Dynamic = field(node, "loc"),
			file:String = field(node, "_hxiFile"),
			line:Dynamic = field(location, "line"),
			column:Dynamic = field(location, "col");
		return '${file == null ? "<header>" : file}:${line == null ? "?" : line}:${column == null ? "?" : column}';
	}

	public static function pathKey(path:String):String
		return StringTools.replace(path, "\\", "/");

	static function sourceFile(path:String):SourceFile {
		var cached = sourceFiles.get(path);
		if (cached != null)
			return cached;
		var source = new SourceFile(path, FileSystem.exists(path) ? File.getContent(path) : "");
		sourceFiles.set(path, source);
		return source;
	}

	static function sourceRange(defaultFile:String, begin:Dynamic, end:Dynamic):String {
		var start:Dynamic = field(begin, "offset"),
			finish:Dynamic = field(end, "offset"),
			tokenLength:Dynamic = field(end, "tokLen");
		if (start == null || finish == null)
			return "";
		var sourcePath:String = field(begin, "file"),
			source = File.getContent(sourcePath == null ? defaultFile : sourcePath);
		return source.substring(start, finish + (tokenLength == null ? 1 : tokenLength));
	}
}
