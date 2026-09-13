function main():Int {
	var ascii = String.fromCharCode(321);
	var nul = String.fromCharCode(256);
	return ascii == "A" && ascii.length == 1 && ascii.charCodeAt(0) == 65 && nul.length == 0 && nul == "" ? 42 : 0;
}
