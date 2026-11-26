// A toString a raw-value enum or a Flags enum abstract declares itself wins over the one the compiler synthesizes; the
// members it does not declare are still synthesized. A raw-value enum's rawValue and fromRaw are always the compiler's.
enum Code:Int {
	Low = 1;
	High = 7;

	public function toString():String
		return "code " + this.rawValue;
}

enum abstract Perm(Int) implements Flags {
	var Read = 1;
	var Write = 2;

	public function toString():String
		return "perm";
}

function main():Int {
	var code = Code.High;
	if (code.toString() != "code 7")
		return 1;
	if ("" + code != "code 7" || '$code' != "code 7")
		return 2;
	if (code.rawValue != 7)
		return 3;
	if (Code.fromRaw(7) != Code.High || Code.fromRaw(1) != Code.Low || Code.fromRaw(0) != null)
		return 4;
	var read = Perm.Read;
	if (read.toString() != "perm" || "" + read != "perm")
		return 5;
	if (!(read | Perm.Write).contains(Perm.Write))
		return 6;
	return 42;
}
