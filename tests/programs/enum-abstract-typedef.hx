// A typedef of an enum abstract reaches the abstract's values, statics and conversions, as the abstract itself does
// (packages re-export generated native enums this way).
enum abstract TypedefCode(Int) implements RawRepresentable {
	var Low = 1;
	var High = 7;
}

enum abstract TypedefAccess(Int) implements Flags {
	var Read = 1;
	var Write = 2;
}

typedef Code = TypedefCode;
typedef Access = TypedefAccess;

function take(code:Code):Int
	return code == Code.High ? 7 : 0;

function main():Int {
	var high = Code.High;
	if (take(high) != 7)
		return 1;
	if (take(Code.Low) != 0)
		return 2;
	if (Code.High.rawValue() != 7)
		return 3;
	var parsed = Code.fromRaw(7);
	if (parsed == null || parsed != Code.High)
		return 4;
	if (Code.fromRaw(3) != null)
		return 5;
	var label = switch high {
		case Code.Low: 1;
		case Code.High: 2;
		default: 0;
	};
	if (label != 2)
		return 6;
	var both = Access.Read | Access.Write;
	if (!both.contains(Access.Write))
		return 7;
	return 42;
}
