import haxe.wire.MessagePack;
import haxe.wire.MessagePackWriter;

@:wire
class WireUser {
	@:wireId(1)
	public var id:Int;
	@:wireId(3)
	public var active:Bool;
	@:wireId(2)
	public var name:String;
}

function main():Int {
	var user = new WireUser();
	user.id = 73;
	user.active = true;
	user.name = "Ada";
	var bytes = MessagePack.encode(user);
	var restored:WireUser = MessagePack.decode(bytes);
	if (restored.id != 73 || !restored.active || restored.name != "Ada")
		return 1;

	var compatible = new MessagePackWriter();
	compatible.writeMapHeader(4);
	compatible.writeInt(99);
	compatible.writeString("future");
	compatible.writeInt(2);
	compatible.writeString("Ada");
	compatible.writeInt(1);
	compatible.writeInt(73);
	compatible.writeInt(3);
	compatible.writeBool(true);
	var reordered:WireUser = MessagePack.decode(compatible.getBytes());
	return reordered.id == 73 && reordered.active && reordered.name == "Ada" ? 43 : 2;
}
