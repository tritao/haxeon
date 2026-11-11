import haxeon.wire.MessagePack;

// The codec of Record is requested from two functions.
@:wire
class Record {
	@:id(1)
	public var id:Int;
	@:id(2)
	public var name:String;
	public function new(id:Int, name:String) {
		this.id = id;
		this.name = name;
	}
}

function save(record:Record):haxe.io.Bytes return MessagePack.encode(record);

function load(bytes:haxe.io.Bytes):Record {
	var restored:Record = MessagePack.decode(bytes);
	return restored;
}

function again(record:Record):Int {
	var restored:Record = MessagePack.decode(MessagePack.encode(record));
	return restored.id;
}

function main():Int {
	var original = new Record(7, "seven");
	var back = load(save(original));
	return back.id == 7 && back.name == "seven" && again(new Record(9, "nine")) == 9 ? 42 : 1;
}
