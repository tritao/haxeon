import haxe.io.Bytes;

function main():Int {
	var allocate:Int->Bytes = Bytes.alloc;
	var bytes = allocate(5);
	bytes.set(0, 104);
	return bytes.length == 5 && bytes.get(0) == 104 ? 42 : 1;
}
