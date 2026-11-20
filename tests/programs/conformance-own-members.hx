// A member an enum abstract declares itself wins over the one its RawRepresentable or Flags conformance synthesizes; the
// members it does not declare are still synthesized.
enum abstract Code(Int) implements RawRepresentable {
	var Low = 1;
	var High = 7;

	public function toString():String
		return "code " + this;

	public static function fromRaw(raw:Int):Null<Code>
		return raw == 0 ? null : High;
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
	if (code.rawValue() != 7)
		return 3;
	if (Code.fromRaw(1) != Code.High || Code.fromRaw(0) != null)
		return 4;
	var read = Perm.Read;
	if (read.toString() != "perm" || "" + read != "perm")
		return 5;
	if (!(read | Perm.Write).contains(Perm.Write))
		return 6;
	return 42;
}
