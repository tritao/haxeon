import Wasm32BytesView;
import haxe.io.Bytes;

function main():Int {
	var backing = Bytes.ofString("!slice?"), view = Bytes.view(backing, 1, 5);
	if (Wasm32BytesView.inspect(view) != 42 || Wasm32BytesView.inspect_slice(backing, 1, 5) != 42)
		return 0;
	return 42;
}
