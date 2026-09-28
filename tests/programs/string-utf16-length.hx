// HashLink String lengths count UTF-16 code units, including literals outside the BMP.
function main():Int {
	var accented = "café";
	var astral = "a😀b";
	if (accented.length != 4 || astral.length != 4)
		return 1;
	if (astral.charCodeAt(1) != 0xD83D || astral.charCodeAt(2) != 0xDE00 || astral.charCodeAt(3) != "b".code)
		return 2;
	var joined = accented + astral;
	return joined.length == 8 && joined.substring(4) == astral ? 42 : 3;
}
