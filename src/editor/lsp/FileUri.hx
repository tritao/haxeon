package editor.lsp;

import haxe.io.Bytes;
import haxe.io.BytesBuffer;

/**
	`file:` URIs (RFC 8089) and the paths they name. A URI's path is percent-encoded UTF-8 (RFC 3986): `%XX` is a byte and
	every other character is itself. In particular `+` is a plus, not a space as in form encoding, so `StringTools.urlDecode`
	must not be used here: it would read the directory `c++` as `c  `.
**/
class FileUri {
	static final windows:Bool = Sys.systemName() == "Windows";

	/** The path a `file:` URI names; anything else is returned unchanged. */
	public static function toPath(uri:String):String {
		if (!StringTools.startsWith(uri, "file://"))
			return uri;
		var path = uri.substr(7);
		// The authority is empty or `localhost` for a local file.
		if (StringTools.startsWith(path, "localhost/"))
			path = path.substr(9);
		path = decode(path);
		// file:///C:/x carries a slash before the Windows drive letter.
		return windows && ~/^\/[A-Za-z]:/.match(path) ? path.substr(1) : path;
	}

	/** The `file:` URI of an absolute path. */
	public static function fromPath(path:String):String {
		if (StringTools.startsWith(path, "file://"))
			return path;
		if (windows)
			path = StringTools.replace(path, "\\", "/");
		return (windows && ~/^[A-Za-z]:/.match(path) ? "file:///" : "file://") + encode(path);
	}

	/** Percent-decodes `text` as UTF-8, leaving a `%` that does not start an escape as it is. */
	static function decode(text:String):String {
		if (text.indexOf("%") < 0)
			return text;
		var source = Bytes.ofString(text), bytes = new BytesBuffer(), index = 0;
		while (index < source.length) {
			var byte = source.get(index);
			if (byte == "%".code
				&& index + 2 < source.length
				&& hexDigit(source.get(index + 1)) >= 0
				&& hexDigit(source.get(index + 2)) >= 0) {
				bytes.addByte(hexDigit(source.get(index + 1)) * 16 + hexDigit(source.get(index + 2)));
				index += 3;
			} else {
				bytes.addByte(byte);
				index++;
			}
		}
		return bytes.getBytes().toString();
	}

	/** Percent-encodes every byte of `path` but the unreserved characters, `/` and a drive's `:`. */
	static function encode(path:String):String {
		var source = Bytes.ofString(path), text = new StringBuf();
		for (index in 0...source.length) {
			var byte = source.get(index);
			if (unreserved(byte) || byte == "/".code || (byte == ":".code && windows && index == 1))
				text.addChar(byte);
			else
				text.add("%" + StringTools.hex(byte, 2));
		}
		return text.toString();
	}

	static function unreserved(byte:Int):Bool
		return (byte >= "a".code && byte <= "z".code)
			|| (byte >= "A".code && byte <= "Z".code)
			|| (byte >= "0".code && byte <= "9".code)
			|| byte == "-".code
			|| byte == ".".code
			|| byte == "_".code
			|| byte == "~".code;

	static function hexDigit(byte:Int):Int {
		if (byte >= "0".code && byte <= "9".code)
			return byte - "0".code;
		if (byte >= "a".code && byte <= "f".code)
			return byte - "a".code + 10;
		if (byte >= "A".code && byte <= "F".code)
			return byte - "A".code + 10;
		return -1;
	}
}
