import haxeon.wire.JsonWire;
import haxeon.wire.JsonWireWriter;
import haxeon.wire.MessagePack;
import haxeon.wire.MessagePackWriter;

@:wire struct WireFrame {
	@:id(1) public final x:Float;
	@:id(2) public final y:Float;
	public function new(x:Float, y:Float) {
		this.x = x;
		this.y = y;
	}
}
@:wire typedef WireItem = {
	@:id(1) var id:String;
	@:id(2) var frame:WireFrame;
}
@:wire typedef WireDocument = {
	@:id(1) var items:Array<WireItem>;
	@:id(2) @:optional var optional:Null<WireFrame>;
	@:id(3) var frames:Array<WireFrame>;
}
@:wire class WireHolder {
	@:id(1) public final frame:WireFrame;
	public function new(frame:WireFrame) this.frame = frame;
}
abstract WireFrameAlias(WireFrame) from WireFrame to WireFrame {}
@:wire class WireAliasHolder {
	@:id(1) public final frame:WireFrameAlias;
	public function new(frame:WireFrameAlias) this.frame = frame;
}
function main():Int {
	var original:WireDocument = {
		items: [{id: "part", frame: new WireFrame(1.25, 2.5)}],
		optional: new WireFrame(3.5, 4.5),
		frames: [new WireFrame(8, 9)]
	};
	var json:WireDocument = JsonWire.decode(JsonWire.encode(original));
	var jsonOptional = json.optional;
	if (jsonOptional == null || json.items[0].frame.x != 1.25
		|| json.items[0].frame.y != 2.5 || jsonOptional.x != 3.5 || json.frames[0].x != 8) return 1;
	var binary:WireDocument = MessagePack.decode(MessagePack.encode(original));
	var binaryOptional = binary.optional;
	if (binaryOptional == null
		|| binary.items[0].frame.x != 1.25 || binaryOptional.y != 4.5 || binary.frames[0].y != 9) return 2;
	var holder = new WireHolder(new WireFrame(6.0, 7.0));
	var jsonHolder:WireHolder = JsonWire.decode(JsonWire.encode(holder));
	var binaryHolder:WireHolder = MessagePack.decode(MessagePack.encode(holder));
	if (jsonHolder.frame.x != 6.0 || binaryHolder.frame.y != 7.0) return 3;
	var aliasHolder = new WireAliasHolder(new WireFrame(11.0, 12.0));
	var jsonAlias:WireAliasHolder = JsonWire.decode(JsonWire.encode(aliasHolder));
	var binaryAlias:WireAliasHolder = MessagePack.decode(MessagePack.encode(aliasHolder));
	var jsonAliasFrame:WireFrame = jsonAlias.frame;
	var binaryAliasFrame:WireFrame = binaryAlias.frame;
	if (jsonAliasFrame.x != 11.0 || binaryAliasFrame.y != 12.0) return 10;
	var duplicate = new JsonWireWriter();
	duplicate.writeMapHeader(2);
	for (n in 1...3) {
		duplicate.writeFieldKey(1, "frame");
		duplicate.writeMapHeader(2);
		duplicate.writeFieldKey(1, "x");
		duplicate.writeFloat(n);
		duplicate.writeFieldKey(2, "y");
		duplicate.writeFloat(n);
	}
	var replaced:WireHolder = JsonWire.decode(duplicate.getString());
	if (replaced.frame.x != 2.0) return 9;
	var none:WireDocument = {items: [], optional: null, frames: []};
	var jsonNone:WireDocument = JsonWire.decode(JsonWire.encode(none));
	var binaryNone:WireDocument = MessagePack.decode(MessagePack.encode(none));
	if (jsonNone.optional != null || binaryNone.optional != null) return 4;
	var jsonMissing = new JsonWireWriter();
	jsonMissing.writeMapHeader(0);
	try {
		var absent:WireHolder = JsonWire.decode(jsonMissing.getString());
		return 5;
	} catch (error:Dynamic) {
		if (Std.string(error).indexOf('Missing required MessagePack field "WireHolder.frame"') < 0) return 6;
	}
	var missing = new MessagePackWriter();
	missing.writeMapHeader(0);
	try {
		var absent:WireHolder = MessagePack.decode(missing.getBytes());
		return 7;
	} catch (error:Dynamic) {
		if (Std.string(error).indexOf('Missing required MessagePack field "WireHolder.frame"') < 0) return 8;
	}
	return 42;
}
