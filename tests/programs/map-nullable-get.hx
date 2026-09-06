enum Entry {
	Number(value:Int);
}

class Main {
	static function main():Int {
		var entries = new Map<String, Entry>();
		entries.set("present", Number(42));
		var present = switch entries.get("present") {
			case Number(value): value;
			case null: 0;
		};
		var missing = switch entries.get("missing") {
			case Number(_): 0;
			case null: 42;
		};
		return present == 42 ? missing : 0;
	}
}
