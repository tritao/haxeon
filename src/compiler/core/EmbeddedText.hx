package compiler.core;

import compiler.core.Diagnostic.CompileError;
import compiler.core.Source.SourceSpan;
import haxe.crypto.Sha256;
import haxe.io.Bytes;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;

typedef EmbeddedInput = {
	final path:String;
	final digest:String;
}

/** Reads and records the external text inputs of one module parse. */
class EmbeddedText {
	var values:Null<Map<String, {input:EmbeddedInput, text:String}>>;

	public function new() {}

	public function read(relative:String, span:SourceSpan):String {
		if (relative.length == 0 || Path.isAbsolute(relative))
			throw error("Embed.text requires a nonempty relative path", span);
		for (index in 0...relative.length)
			if (relative.charCodeAt(index) == 0)
				throw error("Embed.text paths cannot contain NUL", span);
		var path = try Path.normalize(FileSystem.absolutePath(Path.join([
			Path.directory(span.file.physicalPath),
			relative
		])))
			catch (_:Dynamic) throw error('Could not resolve embedded text "$relative"', span);
		if (values == null)
			values = new Map();
		var cached = values.get(path);
		if (cached != null)
			return cached.text;

		var bytes = try FileVersion.unchangedRead(path, File.getBytes, 4) catch (_:Dynamic) null;
		if (bytes == null)
			throw error('Could not read embedded text "$relative"', span);
		if (!validUtf8(bytes))
			throw error('Embedded text "$relative" is not valid UTF-8', span);
		var text = bytes.toString();
		values.set(path, {input: {path: path, digest: Sha256.make(bytes).toHex()}, text: text});
		return text;
	}

	public function inputs():Array<EmbeddedInput>
		return values == null ? [] : [for (value in values) value.input];

	public static function changed(input:EmbeddedInput):Bool
		return currentDigest(input.path) != input.digest;

	/** The digest of the file at `path` as it is now, or an empty string when it cannot be read. */
	public static function currentDigest(path:String):String
		return try Sha256.make(File.getBytes(path)).toHex() catch (_:Dynamic) "";

	static function error(message:String, span:SourceSpan):CompileError
		return new CompileError(new Diagnostic(DiagnosticCode.SYNTAX_ERROR, message, span));

	static function validUtf8(bytes:Bytes):Bool {
		var index = 0;
		while (index < bytes.length) {
			var first = bytes.get(index++);
			if (first < 0x80)
				continue;
			if (first < 0xc2 || first > 0xf4)
				return false;
			var count = first < 0xe0 ? 1 : first < 0xf0 ? 2 : 3;
			if (index + count > bytes.length)
				return false;
			// Exclude overlong encodings, UTF-16 surrogates, and values above U+10FFFF.
			var second = bytes.get(index);
			var low = first == 0xe0 ? 0xa0 : first == 0xf0 ? 0x90 : 0x80;
			var high = first == 0xed ? 0x9f : first == 0xf4 ? 0x8f : 0xbf;
			if (second < low || second > high)
				return false;
			index++;
			for (_ in 1...count) {
				var next = bytes.get(index++);
				if (next < 0x80 || next > 0xbf)
					return false;
			}
		}
		return true;
	}
}
