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
		var start = lineStarts[line],
			end = line + 1 < lineStarts.length ? lineStarts[line + 1] - 1 : source.length;
		if (character > end - start)
			throw "LSP position is outside the document";
		return start + character;
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
		return {line: line, character: requested - lineStarts[line]};
	}

	public function range(start:Int, end:Int):Dynamic
		return {start: position(start), end: position(end)};

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
