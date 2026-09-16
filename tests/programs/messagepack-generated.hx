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

@:wire
class WireEnvelope {
	@:wireId(1)
	public var user:Null<WireUser>;
	@:wireId(2)
	public var note:Null<String>;
	@:wireId(3)
	public var count:Null<Int>;
	@:wireId(4)
	public var tags:Array<String>;
	@:wireId(5)
	public var users:Array<WireUser>;
	@:wireId(6)
	public var optionalCounts:Array<Null<Int>>;
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
	if (reordered.id != 73 || !reordered.active || reordered.name != "Ada")
		return 2;

	var envelope = new WireEnvelope();
	envelope.user = user;
	envelope.note = null;
	envelope.count = 7;
	envelope.tags = ["wire", "array"];
	envelope.users = [user];
	envelope.optionalCounts = [1, null, 3];
	var envelopeBytes = MessagePack.encode(envelope);
	var restoredEnvelope:WireEnvelope = MessagePack.decode(envelopeBytes);
	if (restoredEnvelope.user == null
		|| restoredEnvelope.user.id != 73
		|| !restoredEnvelope.user.active
		|| restoredEnvelope.user.name != "Ada"
		|| restoredEnvelope.note != null
		|| restoredEnvelope.count != 7
		|| restoredEnvelope.tags.length != 2
		|| restoredEnvelope.tags[0] != "wire"
		|| restoredEnvelope.tags[1] != "array"
		|| restoredEnvelope.users.length != 1
		|| restoredEnvelope.users[0].name != "Ada"
		|| restoredEnvelope.optionalCounts.length != 3
		|| restoredEnvelope.optionalCounts[0] != 1
		|| restoredEnvelope.optionalCounts[1] != null
		|| restoredEnvelope.optionalCounts[2] != 3)
		return 3;

	var users:Array<WireUser> = [user];
	var restoredUsers:Array<WireUser> = MessagePack.decode(MessagePack.encode(users));
	if (restoredUsers.length != 1 || restoredUsers[0].id != 73)
		return 4;

	var optionalUser:Null<WireUser> = user;
	var optionalBytes = MessagePack.encode(optionalUser);
	var restoredOptional:Null<WireUser> = MessagePack.decode(optionalBytes);
	if (restoredOptional == null || restoredOptional.id != 73)
		return 5;
	optionalUser = null;
	var nullBytes = MessagePack.encode(optionalUser);
	var restoredNull:Null<WireUser> = MessagePack.decode(nullBytes);
	return restoredNull == null ? 43 : 6;
}
