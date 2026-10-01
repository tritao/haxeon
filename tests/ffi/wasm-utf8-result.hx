import Utf8Result;
import haxe.io.Bytes;

function main():Int {
	var text = Utf8Result.text();
	if (text.length != 3 || text.charCodeAt(0) != 233 || text.substring(1) != "🙂")
		return 1;
	var optional = Utf8Result.optional(1);
	if (optional == null || optional != text || Utf8Result.optional(0) != null)
		return 2;
	Utf8Result.overwrite();
	if (text != "é🙂" || optional != "é🙂" || Bytes.ofString(text).length != 6)
		return 3;
	return 42;
}
