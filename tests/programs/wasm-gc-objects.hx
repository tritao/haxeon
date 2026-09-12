class WasmGcObjectBase {
	public var value:Int;

	public function new() {
		value = 40;
	}
}

class WasmGcObjectChild extends WasmGcObjectBase {
	public var other:WasmGcObjectChild;

	public function new() {
		super();
	}
}

class WasmGcObjectRegistry {
	public static var current:WasmGcObjectChild;
}

function main():Int {
	var first = new WasmGcObjectChild();
	var second = new WasmGcObjectChild();
	first.other = second;
	WasmGcObjectRegistry.current = second;
	return first.other != null && WasmGcObjectRegistry.current != null && first.value == 40 ? 42 : 0;
}
