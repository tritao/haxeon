class WasmGcEnumItem {
	public var value:Int;

	public function new(value:Int) {
		this.value = value;
	}
}

enum WasmGcChoice {
	Empty;
	Number(prefix:Int, value:Float);
	Item(value:WasmGcEnumItem);
}

function main():Int {
	var number:WasmGcChoice = WasmGcChoice.Number(7, 40.5),
		numberResult = switch (number) {
			case Number(prefix, value): prefix + (value == 40.5 ? 35 : 0);
			case Item(_): 0;
			case Empty: 0;
		};
	var item:WasmGcChoice = WasmGcChoice.Item(new WasmGcEnumItem(42)),
		itemResult = switch (item) {
			case Item(value): value.value;
			case Number(_, _): 0;
			case Empty: 0;
		};
	var empty:WasmGcChoice = WasmGcChoice.Empty;
	var emptyResult = switch (empty) {
		case Empty: 1;
		case Number(_, _): 0;
		case Item(_): 0;
	};
	return numberResult == 42 && itemResult == 42 && emptyResult == 1 ? 42 : 0;
}
