package compiler.service;

import compiler.core.InternalError;
import compiler.core.Source.SourceFile;

/**
 * Replacements in a source file at token offsets, which count UTF-8 bytes. A Haxe string index counts characters, so an edit
 * made with `substr` at a token offset lands in the wrong place once a character before it takes more than one byte; every
 * rewrite a tool makes goes through here instead.
 */
class SourceEdits {
	final file:SourceFile;
	final edits:Array<{start:Int, end:Int, text:String}> = [];

	public function new(file:SourceFile)
		this.file = file;

	public function replace(start:Int, end:Int, text:String):Void {
		if (start < 0 || end < start || end > file.bytes.length)
			throw new InternalError('Edit $start...$end is outside "${file.path}"');
		edits.push({start: start, end: end, text: text});
	}

	/** Removes `start...end`, with its line when nothing else is on it. */
	public function removeStatement(start:Int, end:Int):Void {
		var lineStart = lineStartAt(file, start), lineEnd = lineEndAt(file, end);
		if (isBlank(file, lineStart, start) && isBlank(file, end, lineEnd))
			replace(lineStart, lineEnd < file.bytes.length ? lineEnd + 1 : lineEnd, "");
		else
			replace(start, end, "");
	}

	/** The file's text with every edit made. Edits may not overlap. */
	public function apply():String {
		var ordered = edits.copy();
		ordered.sort((left, right) -> left.start - right.start);
		var result = new StringBuf(), position = 0;
		for (edit in ordered) {
			if (edit.start < position)
				throw new InternalError('Edits overlap at ${edit.start} in "${file.path}"');
			result.add(file.slice(position, edit.start));
			result.add(edit.text);
			position = edit.end;
		}
		result.add(file.slice(position, file.bytes.length));
		return result.toString();
	}

	/** The offset where the line holding `offset` starts. */
	public static function lineStartAt(file:SourceFile, offset:Int):Int {
		var cursor = offset;
		while (cursor > 0 && file.bytes.get(cursor - 1) != "\n".code)
			cursor--;
		return cursor;
	}

	/** The offset of the newline that ends the line holding `offset`, or the file's end. */
	public static function lineEndAt(file:SourceFile, offset:Int):Int {
		var cursor = offset;
		while (cursor < file.bytes.length && file.bytes.get(cursor) != "\n".code)
			cursor++;
		return cursor;
	}

	/** Whether `start...end` holds only spaces, tabs and carriage returns. */
	public static function isBlank(file:SourceFile, start:Int, end:Int):Bool {
		for (offset in start...end)
			switch file.bytes.get(offset) {
				case " ".code | "\t".code | "\r".code:
				default:
					return false;
			}
		return true;
	}
}
