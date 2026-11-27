import haxeon.wire.JsonWire;
import haxeon.wire.MessagePack;

private enum State {
	Waiting;
	Ready(value:Int);
}

private enum Status {
	Open;
	Closed;
}

private class Document {
	public final state:State;
	public final title:String;
	public final retired:Array<Int>;
	public final statuses:Map<Status, Int>;

	public function new() {
		state = Ready(42);
		title = "motor";
		retired = [1, 2];
		statuses = [Open => 3, Closed => 7];
	}
}

@:wire
private enum PinnedState {
	@:id(7) Ready(value:Int);
	@:id(4) Waiting;
}

@:wire
private enum PinnedStatus {
	@:id(3) Closed;
	@:id(8) Open;
}

@:wire
private class PinnedDocument {
	@:id(3) public final statuses:Map<PinnedStatus, Int>;
	@:id(8) public final title:String;
	@:id(1) public final state:PinnedState;
}

function main():Int {
	var old = new Document();
	var bytes = MessagePack.encode(old);
	var json = JsonWire.encode(old);
	var fromBytes:PinnedDocument = MessagePack.decode<PinnedDocument>(bytes).unwrap();
	var fromJson:PinnedDocument = JsonWire.decode<PinnedDocument>(json).unwrap();
	if (!matches(fromBytes) || !matches(fromJson))
		return 1;

	var numberedBytes = MessagePack.encode(fromJson);
	var numberedJson = JsonWire.encode(fromBytes);
	if (numberedBytes.toHex() != "83018107912a03820307080308a56d6f746f72")
		return 2;
	if (numberedJson
		!= '{"version":1,"value":[["1:state",[["7:Ready",[42]]]],["3:statuses",[[3,7],[8,3]]],["8:title","motor"]]}')
		return 3;
	var decodedBytes:PinnedDocument =
		MessagePack.decode<PinnedDocument>(numberedBytes).unwrap();
	var decodedJson:PinnedDocument =
		JsonWire.decode<PinnedDocument>(numberedJson).unwrap();
	return matches(decodedBytes) && matches(decodedJson) ? 42 : 4;
}

function matches(value:PinnedDocument):Bool {
	return value.title == "motor" && value.statuses[PinnedStatus.Open] == 3
		&& value.statuses[PinnedStatus.Closed] == 7
		&& switch value.state {
			case Ready(value): value == 42;
			case Waiting: false;
		};
}
