/** Base64 round trips, padding, a non-ASCII character, and a large decode that must stay linear (wasm32 indexed the String per character). */
import haxe.crypto.Base64;
import haxe.io.Bytes;
function main():Int {
	for (n in 0...40) {
		var bytes = Bytes.alloc(n);
		for (i in 0...n) bytes.set(i, (i * 37 + 11) & 0xFF);
		var text = Base64.encode(bytes);
		var back = Base64.decode(text);
		if (back.compare(bytes) != 0) return 1;
		var bare = Base64.encode(bytes, false);
		if (Base64.decode(bare, false).compare(bytes) != 0) return 2;
	}
	if (Base64.decode("aGk=").toString() != "hi") return 3;
	try {
		Base64.decode("a€bc");
		return 4;
	} catch (e:Dynamic) {}
	var big = Bytes.alloc(300000);
	for (i in 0...big.length) big.set(i, i & 0xFF);
	if (Base64.decode(Base64.encode(big)).compare(big) != 0) return 5;
	return 42;
}
