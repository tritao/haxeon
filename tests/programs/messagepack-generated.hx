import haxe.wire.MessagePack;

@:wire
class WireUser {
	public var id:Int;
	public var active:Bool;
	public var name:String;
}

function main():Int {
	var user = new WireUser();
	user.id = 73;
	user.active = true;
	user.name = "Ada";
	var bytes = MessagePack.encode(user);
	var restored:WireUser = MessagePack.decode(bytes);
	return restored.id == 73 && restored.active && restored.name == "Ada" ? 43 : 1;
}
