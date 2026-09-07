package editor.lsp;

/** One open LSP document with monotonically versioned text and position conversion. */
class LspDocument {
	public final uri:String;
	public final path:String;
	public var version(default, null):Int;
	public var source(default, null):String;

	var lineStarts:Array<Int>;

	public function new(uri:String, path:String, version:Int, source:String) {
		this.uri = uri;
		this.path = path;
		this.version = version;
		this.source = source;
		rebuildLines();
	}

	public function replace(version:Int, source:String):Bool {
		if (version <= this.version)
			return false;
		this.version = version;
		this.source = source;
		rebuildLines();
		return true;
	}

	public function offset(line:Int, character:Int):Int {
		if (line < 0 || character < 0 || line >= lineStarts.length)
			throw "LSP position is outside the document";
		var start = lineStarts[line], end = lineEnd(line), offset = start, units = 0;
		while (offset < end && units < character) {
			var width = utf16Width(source.charCodeAt(offset));
			if (units + width > character)
				throw "LSP position splits a UTF-16 surrogate pair";
			units += width;
			offset++;
		}
		if (units != character)
			throw "LSP position is outside the document";
		return offset;
	}

	public function position(requested:Int):Dynamic {
		if (requested < 0 || requested > source.length)
			throw "Compiler position is outside the document";
		var low = 0, high = lineStarts.length;
		while (low < high) {
			var middle = low + ((high - low) >> 1);
			if (lineStarts[middle] <= requested)
				low = middle + 1;
			else
				high = middle;
		}
		var line = low - 1;
		return {line: line, character: utf16Length(source, lineStarts[line], requested)};
	}

	public function range(start:Int, end:Int):Dynamic
		return {start: position(start), end: position(end)};

	public function applyChanges(version:Int, changes:Array<Dynamic>):Bool {
		if (version <= this.version)
			return false;
		if (changes.length == 0)
			throw "LSP document change batch is empty";
		var candidate = source;
		for (change in changes) {
			var text = stringField(change, "text"), range:Dynamic = Reflect.field(change, "range");
			if (range == null)
				candidate = text;
			else {
				var view = new LspDocument(uri, path, this.version, candidate), start = positionField(range, "start"), end = positionField(range, "end"),
					startOffset = view.offset(start.line, start.character), endOffset = view.offset(end.line, end.character);
				if (endOffset < startOffset)
					throw "LSP document change range is reversed";
				var rawLength:Dynamic = Reflect.field(change, "rangeLength");
				if (rawLength != null) {
					if (!Std.isOfType(rawLength, Int) || rawLength < 0)
						throw 'Field "rangeLength" must be a non-negative integer';
					if (rawLength != utf16Length(candidate, startOffset, endOffset))
						throw "LSP document change rangeLength does not match the replaced text";
				}
				candidate = candidate.substring(0, startOffset) + text + candidate.substring(endOffset);
			}
		}
		this.version = version;
		source = candidate;
		rebuildLines();
		return true;
	}

	function lineEnd(line:Int):Int {
		var end = line + 1 < lineStarts.length ? lineStarts[line + 1] - 1 : source.length;
		if (end > lineStarts[line] && source.charCodeAt(end - 1) == 13)
			end--;
		return end;
	}

	static function positionField(value:Dynamic, name:String):{line:Int, character:Int} {
		var position:Dynamic = Reflect.field(value, name);
		if (position == null)
			throw 'Missing field "$name"';
		var line:Dynamic = Reflect.field(position, "line"), character:Dynamic = Reflect.field(position, "character");
		if (!Std.isOfType(line, Int) || !Std.isOfType(character, Int))
			throw "LSP positions require integer line and character fields";
		return {line: cast line, character: cast character};
	}

	static function stringField(value:Dynamic, name:String):String {
		var field:Dynamic = Reflect.field(value, name);
		if (!Std.isOfType(field, String))
			throw 'Field "$name" must be a string';
		return cast field;
	}

	static function utf16Length(value:String, start:Int, end:Int):Int {
		var result = 0;
		for (index in start...end)
			result += utf16Width(value.charCodeAt(index));
		return result;
	}

	static inline function utf16Width(code:Null<Int>):Int
		return code != null && code > 0xffff ? 2 : 1;

	function rebuildLines():Void {
		lineStarts = [0];
		for (index in 0...source.length)
			if (source.charCodeAt(index) == 10)
				lineStarts.push(index + 1);
	}
}

/** Owns open-document identity independently of compiler module state. */
class DocumentStore {
	final byUri:Map<String, LspDocument> = [];
	final uriByPath:Map<String, String> = [];

	public function new() {}

	public function open(uri:String, version:Int, source:String):LspDocument {
		var path = uriPath(uri), previous = byUri.get(uri);
		if (previous != null)
			uriByPath.remove(previous.path);
		var document = new LspDocument(uri, path, version, source);
		byUri.set(uri, document);
		uriByPath.set(path, uri);
		return document;
	}

	public function replace(uri:String, version:Int, source:String):Null<LspDocument> {
		var document = byUri.get(uri);
		if (document == null)
			throw 'Document is not open: $uri';
		return document.replace(version, source) ? document : null;
	}

	public function applyChanges(uri:String, version:Int, changes:Array<Dynamic>):Null<LspDocument> {
		var document = byUri.get(uri);
		if (document == null)
			throw 'Document is not open: $uri';
		return document.applyChanges(version, changes) ? document : null;
	}

	public function close(uri:String):Void {
		var document = byUri.get(uri);
		if (document != null)
			uriByPath.remove(document.path);
		byUri.remove(uri);
	}

	public function get(uri:String):LspDocument {
		var document = byUri.get(uri);
		if (document == null)
			throw 'Document is not open: $uri';
		return document;
	}

	public function forPath(path:String):Null<LspDocument> {
		var uri = uriByPath.get(path);
		return uri == null ? null : byUri.get(uri);
	}

	public function uri(path:String):String {
		var known = uriByPath.get(path);
		return known == null ? pathUri(path) : known;
	}

	static function uriPath(uri:String):String {
		if (!StringTools.startsWith(uri, "file://"))
			return uri;
		var path = uri.substr(7);
		if (StringTools.startsWith(path, "localhost/"))
			path = "/" + path.substr(10);
		return StringTools.urlDecode(path);
	}

	static function pathUri(path:String):String
		return StringTools.startsWith(path, "file://") ? path : "file://" + path;
}
