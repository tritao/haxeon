class WasmGcExceptionMarker {
	public var value:Int;

	public function new(value:Int) {
		this.value = value;
	}
}

function wasmGcThrowValue():Int {
	throw 42;
}

function wasmGcThrowObject():Int {
	throw new WasmGcExceptionMarker(42);
}

function wasmGcReadOutOfBounds():Int {
	var values = [1];
	return values[2];
}

function main():Int {
	var result = 0;
	try {
		wasmGcThrowValue();
	} catch (error:Dynamic) {
		result = cast(error, Int);
	}
	if (result != 42)
		return 0;
	var markerValue = 0;
	try {
		wasmGcThrowObject();
	} catch (error:Dynamic) {
		var marker:WasmGcExceptionMarker = cast(error, WasmGcExceptionMarker);
		markerValue = marker.value;
	}
	if (markerValue != 42)
		return 0;
	try {
		wasmGcReadOutOfBounds();
	} catch (error:Dynamic) {
		return 42;
	}
	return 0;
}
