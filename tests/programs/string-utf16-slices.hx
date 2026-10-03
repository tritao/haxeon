import haxe.io.Bytes;

function main():Int {
	var value = Bytes.ofString("é🙂z").toString();
	if (value.length != 4 || value.substring(0, 1) != "é" || value.substring(1, 3) != "🙂" || value.substring(3) != "z")
		return 1;
	if (value.charAt(0) != "é" || value.charAt(3) != "z" || value.charAt(-1) != "" || value.charAt(4) != "")
		return 2;
	var high = value.substring(1, 2), low = value.substring(2, 3);
	if (high.length != 1 || high.charCodeAt(0) != 0xd83d || low.length != 1 || low.charCodeAt(0) != 0xde42)
		return 3;
	if (value.charAt(1).charCodeAt(0) != 0xd83d || value.charAt(2).charCodeAt(0) != 0xde42)
		return 4;
	if (value.substring(2, 2) != "" || value.substring(-1, 1) != "é" || value.substring(3, 99) != "z")
		return 5;
	if (value.substring(2, 4).charCodeAt(0) != 0xde42 || value.substring(2, 4).charAt(1) != "z")
		return 6;
	return 42;
}
