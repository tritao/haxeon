@:value @:repr("C")
class Pair {
	public var tag:UInt8;
	public var value:Int64;
	public var ratio:Float32;
}

function main():Int {
	var info = typeInfo<Pair>();
	if (info.name != "Pair"
		|| info.size != sizeof<Pair>()
		|| info.alignment != alignof<Pair>()
		|| info.size != 24
		|| info.alignment != 8)
		return 1;
	if (info.fields.length != 3 || info.fields[0].name != "tag" || info.fields[0].offset != offsetof<Pair>("tag"))
		return 2;
	if (info.fields[1].name != "value" || info.fields[1].offset != offsetof<Pair>("value"))
		return 3;
	if (info.fields[2].name != "ratio" || info.fields[2].offset != offsetof<Pair>("ratio"))
		return 4;
	if (info.fields[0].type != "native-scalar:u8" || info.fields[1].type != "haxe.Int64" || info.fields[2].type != "native-scalar:f32")
		return 5;
	if (info.fields[0].annotations.length != 0 || info.fields[1].annotations.length != 0 || info.fields[2].annotations.length != 0)
		return 6;
	if (info.hash != "49856bde4d73d47517451fed037c4e62ef7b91836aa650a2045ba07ff73acd79" || info.hash != typeInfo<Pair>().hash)
		return 7;
	return 42;
}
