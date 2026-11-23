import haxeon.wire.JsonWire;
import haxeon.wire.JsonWireWriter;
import haxeon.wire.MessagePack;
import haxeon.wire.MessagePackWriter;

enum State {
	Waiting;
	Ready(value:Int);
}

class Box {
	public final state:State;

	public function new(state:State)
		this.state = state;
}

typedef Document = {
	var title:String;
	var box:Box;
	?var note:String;
}

typedef ReorderedDocument = {
	?var note:String;
	var box:Box;
	var title:String;
}

enum Status {
	Zebra;
	Ant;
}

function main():Int {
	var doc:Document = {title: "a", box: new Box(Ready(42)), note: null};
	var reordered:ReorderedDocument = doc;
	var json = JsonWire.encode(doc);
	if (json != '{"version":1,"value":{"title":"a","box":{"state":{"Ready":[42]}},"note":null}}'
		|| JsonWire.encode(reordered) != json)
		return 1;
	var jsonWriter = new JsonWireWriter();
	jsonWriter.writeObjectHeader(1);
	jsonWriter.writeString("q\"\\雪");
	jsonWriter.writeString("\x08\t\n\x0c\r\x01雪");
	if (jsonWriter.getString() != '{"version":1,"value":{"q\\"\\\\雪":"\\b\\t\\n\\f\\r\\u0001雪"}}')
		return 7;
	var bytes = MessagePack.encode(doc);
	if (bytes.toHex() != "83a3626f7881a5737461746581a55265616479912aa46e6f7465c0a57469746c65a161"
		|| MessagePack.encode(reordered).compare(bytes) != 0)
		return 2;

	var fromJson:Document = JsonWire.decode(json);
	var fromBytes:Document = MessagePack.decode(bytes);
	if (check(fromJson) != 42 || check(fromBytes) != 42)
		return 3;

	var withUnknown:Document =
		JsonWire.decode('{"version":1,"value":{"title":"a","new":[{"t":true}],"box":{"state":{"Ready":[42]}}}}');
	if (check(withUnknown) != 42)
		return 4;

	var writer = new MessagePackWriter();
	writer.writeMapHeader(3);
	writer.writeString("title");
	writer.writeString("a");
	writer.writeString("new");
	writer.writeArrayHeader(1);
	writer.writeBool(true);
	writer.writeString("box");
	writer.writeMapHeader(1);
	writer.writeString("state");
	writer.writeMapHeader(1);
	writer.writeString("Ready");
	writer.writeArrayHeader(1);
	writer.writeInt(42);
	var missing:Document = MessagePack.decode(writer.getBytes());
	if (check(missing) != 42)
		return 5;

	var statuses:Map<Status, Int> = [Zebra => 2, Ant => 40];
	var statusBytes = MessagePack.encode(statuses);
	var statusJson = JsonWire.encode(statuses);
	if (statusBytes.toHex() != "82a3416e7428a55a6562726102")
		return 6;
	var mpStatuses:Map<Status, Int> = MessagePack.decode(statusBytes);
	var jsonStatuses:Map<Status, Int> = JsonWire.decode(statusJson);
	return (mpStatuses[Zebra] ?? 0) + (jsonStatuses[Ant] ?? 0);
}

function check(doc:Document):Int {
	if (doc.note != null || doc.title != "a")
		return 0;
	return switch doc.box.state {
		case Ready(value): value;
		case Waiting: 1;
	};
}
