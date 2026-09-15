import runtime.memory.NativeString;

function main():Int {
	var ascii = new NativeString("hashlink"),
		unicode = new NativeString("std✓"),
		sameUnicode = new NativeString("std✓");
	if (ascii.length != 8 || ascii.byteAt(0) != 104 || ascii.byteAt(7) != 107 || ascii.data().offset(8).load() != 0)
		return 1;
	if (unicode.length != 6 || unicode.byteAt(3) != 226 || unicode.byteAt(4) != 156 || unicode.byteAt(5) != 147)
		return 2;
	if (!ascii.equalsUtf8("hashlink") || ascii.equals(unicode) || !unicode.equals(sameUnicode))
		return 3;
	if (NativeString.utf8Length("std✓") != 6 || NativeString.utf8Bytes("std✓").length != 6)
		return 4;
	ascii.dispose();
	if (!ascii.isDisposed() || !ascii.data().isNull())
		return 5;
	try {
		ascii.byteAt(0);
		return 6;
	} catch (_:Dynamic) {}
	unicode.dispose();
	sameUnicode.dispose();
	return 42;
}
