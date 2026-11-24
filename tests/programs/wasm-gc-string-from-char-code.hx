function main():Int {
	var ascii = String.fromCharCode(65);
	var latin = String.fromCharCode(321);
	var latinStart = String.fromCharCode(256);
	return ascii == "A" && ascii.length == 1 && ascii.charCodeAt(0) == 65 && latin == "Ł" && latin.length == 1
		&& latin.charCodeAt(0) == 321 && latinStart == "Ā" && latinStart.length == 1
		&& latinStart.charCodeAt(0) == 256 ? 42 : 0;
}
