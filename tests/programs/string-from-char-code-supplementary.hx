import haxe.io.Bytes;

// String.fromCharCode and StringBuf.addChar as on HashLink: a code point above U+FFFF is a surrogate pair, a lone surrogate or a
// code past U+10FFFF throws "Invalid unicode char N".
function main():Int {
	var emoji = String.fromCharCode(0x1F600);
	if (emoji.length != 2 || emoji.charCodeAt(0) != 0xD83D || emoji.charCodeAt(1) != 0xDE00)
		return 1;
	if (emoji != "\u{1F600}" || Bytes.ofString(emoji).toHex() != "f09f9880")
		return 2;
	if (String.fromCharCode(0x10000) != "\u{10000}" || String.fromCharCode(0x10FFFF) != "\u{10FFFF}")
		return 3;
	if (String.fromCharCode(0xE9) != "é" || String.fromCharCode(0xFFFF).length != 1)
		return 4;
	var buffer = new StringBuf();
	buffer.addChar("a".code);
	buffer.addChar(0x1F600);
	buffer.addChar(0x2026);
	buffer.addChar(0x10FFFF);
	if (buffer.length != 6)
		return 5;
	var text = buffer.toString();
	if (text != "a\u{1F600}…\u{10FFFF}" || Bytes.ofString(text).toHex() != "61f09f9880e280a6f48fbfbf")
		return 6;
	for (code in [0xD800, 0xDFFF, 0x110000]) {
		if (invalid(() -> String.fromCharCode(code)) != 'Invalid unicode char $code')
			return 7;
		if (invalid(() -> new StringBuf().addChar(code)) != 'Invalid unicode char $code')
			return 8;
	}
	return 42;
}

function invalid(action:() -> Void):String {
	try {
		action();
	} catch (error:String) {
		return error;
	}
	return "no error";
}
