package haxeon.editor;

import haxe.io.Bytes;
import Observable;

/** Caller-owned editable text whose public revision participates in reactive builds. */
@:allow(haxeon.ui.widgets.text.TextEditorState)
class TextDocument implements Observable {
	public var revision(default, null):Int;
	public var codepointCount(get, never):Int;
	public var utf8ByteLength(get, never):Int;
	public var utf16Length(get, never):Int;
	public var text(get, never):String;
	@:unobservable var buffer:TextDocumentBuffer;

	public function new(value:String) {
		buffer = new TextDocumentBuffer(value);
		revision = buffer.revision;
	}

	private function storage():TextDocumentBuffer return buffer;

	function get_codepointCount():Int {
		var currentRevision = revision;
		return buffer.codepointCount;
	}
	function get_utf8ByteLength():Int {
		var currentRevision = revision;
		return buffer.utf8ByteLength;
	}
	function get_utf16Length():Int {
		var currentRevision = revision;
		return buffer.utf16Length;
	}
	function get_text():String {
		var currentRevision = revision;
		return buffer.text;
	}

	public function replace(start:Int, end:Int, replacement:String):Bool {
		if (!buffer.replace(start, end, replacement)) return false;
		revision = buffer.revision;
		return true;
	}

	public function editSince(previous:Int):Null<TextDocumentEdit> {
		var currentRevision = revision;
		return buffer.editSince(previous);
	}
	public function sliceCodepoints(start:Int, end:Int):String {
		var currentRevision = revision;
		return buffer.sliceCodepoints(start, end);
	}
	public function utf8OffsetForCodepoint(position:Int):Int {
		var currentRevision = revision;
		return buffer.utf8OffsetForCodepoint(position);
	}
	public function utf16OffsetForCodepoint(position:Int):Int {
		var currentRevision = revision;
		return buffer.utf16OffsetForCodepoint(position);
	}
	public function codepointOffsetForUtf8(position:Int):Int {
		var currentRevision = revision;
		return buffer.codepointOffsetForUtf8(position);
	}
	public function codepointOffsetForUtf16(position:Int):Int {
		var currentRevision = revision;
		return buffer.codepointOffsetForUtf16(position);
	}
	public function paragraphCount():Int {
		var currentRevision = revision;
		return buffer.paragraphCount();
	}
	public function paragraphIndexAtOffset(position:Int):Int {
		var currentRevision = revision;
		return buffer.paragraphIndexAtOffset(position);
	}
	public function paragraphRangeAtIndex(number:Int):TextRange {
		var currentRevision = revision;
		return buffer.paragraphRangeAtIndex(number);
	}
}

/** Text storage and indexes used by a widget's private editor state. */
class TextDocumentBuffer {
	static inline var targetBytes:Int = 2048;
	/** Incremented after each non-no-op replacement. */
	public var revision(default, null):Int;
	public var codepointCount(default, null):Int;
	public var utf8ByteLength(default, null):Int;
	public var utf16Length(default, null):Int;
	public var text(get, never):String;

	var segments:Array<TextOffsetMap>;
	var codepointStarts:Array<Int>;
	var byteStarts:Array<Int>;
	var utf16Starts:Array<Int>;
	var paragraphStarts:Array<Int>;
	var cachedText:Null<String>;
	var lastEdit:Null<TextDocumentEdit>;

	public function new(value:String) {
		revision = 0;
		segments = split(value == null ? "" : value);
		codepointStarts = [];
		byteStarts = [];
		utf16Starts = [];
		paragraphStarts = [];
		cachedText = value == null ? "" : value;
		reindex();
	}

	public function get_text():String {
		if (cachedText == null) {
			var buffer = new StringBuf();
			for (segment in segments)
				buffer.add(segment.text);
			cachedText = buffer.toString();
		}
		return cachedText;
	}

	public function replace(start:Int, end:Int, replacement:String):Bool {
		checkRange(start, end);
		var inserted = replacement == null ? "" : replacement;
		if (start == end && inserted.length == 0)
			return false;
		if (inserted == sliceCodepoints(start, end))
			return false;
		var first = segmentAt(start);
		var last = segmentAt(end);
		var localStart = start - codepointStarts[first];
		var localEnd = end - codepointStarts[last];
		var changed = segments[first].sliceCodepoints(0, localStart) + inserted +
			segments[last].sliceCodepoints(localEnd, segments[last].codepointCount);
		var replacementSegments = split(changed);
		// A trailing empty segment belongs only at the document end. The next
		// retained segment already owns the paragraph after this newline.
		if (last + 1 < segments.length && replacementSegments.length > 0 &&
			replacementSegments[replacementSegments.length - 1].codepointCount == 0)
			replacementSegments.pop();
		var result:Array<TextOffsetMap> = [];
		for (index in 0...first)
			result.push(segments[index]);
		for (segment in replacementSegments)
			result.push(segment);
		for (index in last + 1...segments.length)
			result.push(segments[index]);
		var previousCount = codepointCount;
		segments = result;
		cachedText = null;
		revision++;
		reindex();
		lastEdit = new TextDocumentEdit(revision, start, end, start + TextOffsetMap.countCodepoints(inserted), previousCount);
		return true;
	}

	/** The replacement that turned revision `previous` into the current one, or null when that took more than one
		replacement (or none). Lets a view of the document update only what the edit touched. */
	public function editSince(previous:Int):Null<TextDocumentEdit> {
		var edit = lastEdit;
		return edit != null && edit.revision == revision && previous == revision - 1 ? edit : null;
	}

	public function sliceCodepoints(start:Int, end:Int):String {
		checkRange(start, end);
		if (start == end)
			return "";
		var buffer = new StringBuf();
		var first = segmentAt(start);
		var last = segmentAt(end);
		for (index in first...last + 1) {
			var localStart = index == first ? start - codepointStarts[index] : 0;
			var localEnd = index == last ? end - codepointStarts[index] : segments[index].codepointCount;
			if (localEnd > localStart)
				buffer.add(segments[index].sliceCodepoints(localStart, localEnd));
		}
		return buffer.toString();
	}

	public function utf8OffsetForCodepoint(position:Int):Int {
		checkPosition(position);
		var index = segmentAt(position);
		return byteStarts[index] + segments[index].utf8OffsetForCodepoint(position - codepointStarts[index]);
	}

	public function utf16OffsetForCodepoint(position:Int):Int {
		checkPosition(position);
		var index = segmentAt(position);
		return utf16Starts[index] + segments[index].utf16OffsetForCodepoint(position - codepointStarts[index]);
	}

	public function codepointOffsetForUtf8(position:Int):Int {
		if (position < 0 || position > utf8ByteLength)
			throw "UTF-8 offset is outside the document";
		var index = segmentAtPrefix(byteStarts, position);
		return codepointStarts[index] + segments[index].codepointOffsetForUtf8(position - byteStarts[index]);
	}

	public function codepointOffsetForUtf16(position:Int):Int {
		if (position < 0 || position > utf16Length)
			throw "UTF-16 offset is outside the document";
		var index = segmentAtPrefix(utf16Starts, position);
		return codepointStarts[index] + segments[index].codepointOffsetForUtf16(position - utf16Starts[index]);
	}

	public function paragraphCount():Int
		return paragraphStarts[paragraphStarts.length - 1] + segments[segments.length - 1].paragraphCount();

	public function paragraphIndexAtOffset(position:Int):Int {
		checkPosition(position);
		var index = segmentAt(position);
		return paragraphStarts[index] + segments[index].paragraphIndexAtOffset(position - codepointStarts[index]);
	}

	public function paragraphRangeAtIndex(number:Int):TextRange {
		if (number < 0 || number >= paragraphCount())
			throw "Paragraph index is outside the document";
		var first = segmentAtPrefix(paragraphStarts, number);
		while (first > 0 && paragraphStarts[first - 1] +
			segments[first - 1].paragraphCount() - 1 >= number)
			first--;
		var firstRange = segments[first].paragraphRangeAtIndex(number - paragraphStarts[first]);
		var start = codepointStarts[first] + firstRange.start;
		var end = codepointStarts[first] + firstRange.end;
		for (index in (first + 1)...segments.length) {
			if (paragraphStarts[index] > number)
				break;
			var localParagraph = number - paragraphStarts[index];
			if (localParagraph < segments[index].paragraphCount()) {
				var range = segments[index].paragraphRangeAtIndex(localParagraph);
				end = codepointStarts[index] + range.end;
			}
		}
		return new TextRange(start, end);
	}

	function segmentAt(position:Int):Int
		return segmentAtPrefix(codepointStarts, position);

	static function segmentAtPrefix(starts:Array<Int>, position:Int):Int {
		var low = 0;
		var high = starts.length - 1;
		while (low <= high) {
			var middle = (low + high) >> 1;
			if (starts[middle] <= position)
				low = middle + 1;
			else
				high = middle - 1;
		}
		return high;
	}

	function reindex():Void {
		var codepoints = 0;
		var bytes = 0;
		var utf16 = 0;
		var paragraphs = 0;
		codepointStarts = [];
		byteStarts = [];
		utf16Starts = [];
		paragraphStarts = [];
		for (segment in segments) {
			codepointStarts.push(codepoints);
			byteStarts.push(bytes);
			utf16Starts.push(utf16);
			paragraphStarts.push(paragraphs);
			codepoints += segment.codepointCount;
			bytes += segment.utf8ByteLength;
			utf16 += segment.utf16Length;
			paragraphs += segment.paragraphCount() - 1;
		}
		codepointCount = codepoints;
		utf8ByteLength = bytes;
		utf16Length = utf16;
	}

	static function split(value:String):Array<TextOffsetMap> {
		var bytes = Bytes.ofString(value);
		var result:Array<TextOffsetMap> = [];
		var start = 0;
		while (bytes.length - start > targetBytes) {
			var boundary = start + targetBytes;
			var searchEnd = Std.int(Math.min(bytes.length, boundary + targetBytes));
			var end = -1;
			for (index in boundary...searchEnd)
				if (bytes.get(index) == 10) {
					end = index + 1;
					break;
				}
			if (end < 0) {
				end = boundary;
				while (end > start && (bytes.get(end) & 0xc0) == 0x80)
					end--;
			}
			if (end <= start)
				throw "Document segment boundary did not advance";
			result.push(new TextOffsetMap(bytes.sub(start, end - start).toString()));
			start = end;
		}
		if (start < bytes.length || result.length == 0)
			result.push(new TextOffsetMap(bytes.sub(start, bytes.length - start).toString()));
		else
			result.push(new TextOffsetMap(""));
		return result;
	}

	function checkPosition(position:Int):Void {
		if (position < 0 || position > codepointCount)
			throw "Code-point offset is outside the document";
	}

	function checkRange(start:Int, end:Int):Void {
		if (start < 0 || end < start || end > codepointCount)
			throw "Code-point range is outside the document";
	}
}

/** One replacement, in code points: `[start, oldEnd)` of the previous text became `[start, newEnd)`. */
class TextDocumentEdit {
	/** The revision the replacement produced. */
	public final revision:Int;
	public final start:Int;
	public final oldEnd:Int;
	public final newEnd:Int;
	/** The document's length before the replacement. */
	public final previousCodepointCount:Int;

	public function new(revision:Int, start:Int, oldEnd:Int, newEnd:Int, previousCodepointCount:Int) {
		this.revision = revision;
		this.start = start;
		this.oldEnd = oldEnd;
		this.newEnd = newEnd;
		this.previousCodepointCount = previousCodepointCount;
	}
}
