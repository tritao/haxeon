import haxe.io.Bytes;

function main():Int {
	var encode:String->Bytes = Bytes.ofString;
	var bytes = encode("hello");
	return bytes.length == 5 && bytes.get(0) == 104 ? 42 : 1;
}
