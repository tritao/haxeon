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
enum WireStatus {
	@:wireId(4)
	Idle;
	@:wireId(9)
	Ready(user:WireUser, values:Array<Null<Int>>, ?note:String);
}

@:wire
enum WireKind {
	@:wireId(8)
	Low;
	@:wireId(2)
	High;
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
	@:wireId(7)
	public var usersByName:Map<String, WireUser>;
	@:wireId(8)
	public var optionalCountsByName:Map<String, Null<Int>>;
	@:wireId(9)
	public var countsById:Map<Int, Null<Int>>;
	@:wireId(10)
	public var status:WireStatus;
	@:wireId(11)
	public var optionalStatus:Null<WireStatus>;
	@:wireId(12)
	public var statuses:Array<WireStatus>;
	@:wireId(13)
	public var statusesByName:Map<String, WireStatus>;
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
	envelope.usersByName = ["ada" => user];
	envelope.optionalCountsByName = ["one" => 1, "none" => null];
	envelope.countsById = new Map<Int, Null<Int>>();
	envelope.countsById.set(-1, null);
	envelope.countsById.set(2, 20);
	var status:WireStatus = Ready(user, [1, null]);
	envelope.status = status;
	envelope.optionalStatus = null;
	envelope.statuses = [status, Idle];
	envelope.statusesByName = ["ready" => status, "idle" => Idle];
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
		|| restoredEnvelope.optionalCounts[2] != 3
		|| restoredEnvelope.usersByName.get("ada") == null
		|| restoredEnvelope.usersByName.get("ada").name != "Ada"
		|| restoredEnvelope.optionalCountsByName.get("one") != 1
		|| restoredEnvelope.optionalCountsByName.get("none") != null
		|| restoredEnvelope.countsById.get(-1) != null
		|| restoredEnvelope.countsById.get(2) != 20
		|| restoredEnvelope.optionalStatus != null
		|| restoredEnvelope.statuses.length != 2
		|| restoredEnvelope.statusesByName.get("idle") == null)
		return 3;
	var restoredStatus:WireStatus = MessagePack.decode(MessagePack.encode(status));
	switch restoredStatus {
		case Ready(restoredUser, values, note):
			if (restoredUser.name != "Ada" || values.length != 2 || values[0] != 1 || values[1] != null || note != null)
				return 10;
		default:
			return 11;
	}
	var unknownStatus = new MessagePackWriter();
	unknownStatus.writeMapHeader(1);
	unknownStatus.writeInt(99);
	unknownStatus.writeArrayHeader(0);
	var unknownRejected = false;
	try {
		var ignoredStatus:WireStatus = MessagePack.decode(unknownStatus.getBytes());
	} catch (_:Dynamic) {
		unknownRejected = true;
	}
	if (!unknownRejected)
		return 12;

	var users:Array<WireUser> = [user];
	var restoredUsers:Array<WireUser> = MessagePack.decode(MessagePack.encode(users));
	if (restoredUsers.length != 1 || restoredUsers[0].id != 73)
		return 4;

	var firstScores:Map<String, Int> = [];
	firstScores.set("zulu", 26);
	firstScores.set("alpha", 1);
	var secondScores:Map<String, Int> = [];
	secondScores.set("alpha", 1);
	secondScores.set("zulu", 26);
	var firstScoreBytes = MessagePack.encode(firstScores);
	var secondScoreBytes = MessagePack.encode(secondScores);
	if (firstScoreBytes.compare(secondScoreBytes) != 0)
		return 5;
	var restoredScores:Map<String, Int> = MessagePack.decode(firstScoreBytes);
	if (restoredScores.get("alpha") != 1 || restoredScores.get("zulu") != 26)
		return 6;

	var firstIds:Map<Int, Int> = new Map<Int, Int>();
	firstIds.set(20, 2);
	firstIds.set(-3, 1);
	var secondIds:Map<Int, Int> = new Map<Int, Int>();
	secondIds.set(-3, 1);
	secondIds.set(20, 2);
	var firstIdBytes = MessagePack.encode(firstIds);
	var secondIdBytes = MessagePack.encode(secondIds);
	if (firstIdBytes.compare(secondIdBytes) != 0)
		return 7;
	var restoredIds:Map<Int, Int> = MessagePack.decode(firstIdBytes);
	if (restoredIds.get(-3) != 1 || restoredIds.get(20) != 2)
		return 8;

	var firstKinds:Map<WireKind, Int> = new Map<WireKind, Int>();
	firstKinds.set(Low, 8);
	firstKinds.set(High, 2);
	var secondKinds:Map<WireKind, Int> = new Map<WireKind, Int>();
	secondKinds.set(High, 2);
	secondKinds.set(Low, 8);
	var firstKindBytes = MessagePack.encode(firstKinds);
	var secondKindBytes = MessagePack.encode(secondKinds);
	if (firstKindBytes.compare(secondKindBytes) != 0)
		return 14;
	var restoredKinds:Map<WireKind, Int> = MessagePack.decode(firstKindBytes);
	if (restoredKinds.get(Low) != 8 || restoredKinds.get(High) != 2 || !restoredKinds.exists(High))
		return 15;
	var copiedKinds:Map<WireKind, Int> = restoredKinds.copy();
	if (copiedKinds.get(Low) != 8 || copiedKinds.get(High) != 2)
		return 16;
	if (!copiedKinds.remove(High) || copiedKinds.exists(High))
		return 21;
	var kindCount = 0, kindTotal = 0;
	for (kind => amount in restoredKinds) {
		if (kind != Low && kind != High)
			return 17;
		kindCount++;
		kindTotal += amount;
	}
	if (kindCount != 2 || kindTotal != 10)
		return 18;
	var keyCount = 0;
	for (kind in restoredKinds.keys()) {
		if (kind != Low && kind != High)
			return 19;
		keyCount++;
	}
	if (keyCount != 2)
		return 20;
	var kindAmounts:Array<Int> = [for (kind => amount in restoredKinds) amount];
	if (kindAmounts.length != 2 || kindAmounts[0] + kindAmounts[1] != 10)
		return 22;
	var unknownKind = new MessagePackWriter();
	unknownKind.writeMapHeader(1);
	unknownKind.writeInt(99);
	unknownKind.writeInt(1);
	var unknownKindRejected = false;
	try {
		var ignoredKinds:Map<WireKind, Int> = MessagePack.decode(unknownKind.getBytes());
	} catch (_:Dynamic) {
		unknownKindRejected = true;
	}
	if (!unknownKindRejected)
		return 23;

	var optionalUser:Null<WireUser> = user;
	var optionalBytes = MessagePack.encode(optionalUser);
	var restoredOptional:Null<WireUser> = MessagePack.decode(optionalBytes);
	if (restoredOptional == null || restoredOptional.id != 73)
		return 9;
	optionalUser = null;
	var nullBytes = MessagePack.encode(optionalUser);
	var restoredNull:Null<WireUser> = MessagePack.decode(nullBytes);
	return restoredNull == null ? 43 : 13;
}
