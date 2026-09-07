enum Value {
	Number(value:Int);
}

typedef Entry = {
	final value:Value;
}

function main():Int {
	var entries = new Map<String, Entry>();
	entries.set("answer", {value: Number(42)});
	var entry = entries.get("answer");
	if (entry == null)
		return 0;
	return switch entry.value {
		case Number(value): value;
	};
}
