using compiler.compilation.BackendArtifact.BackendArtifacts;
import compiler.Compiler;
import compiler.runtime.CompilerIntrinsics;
import sys.io.File;

/** Builds a native JSON wire round-trip fixture using the compiler under test. */
class JsonWireMain {
	static function main():Void {
		var compiler = new Compiler();
		CompilerIntrinsics.register(compiler);
		compiler.addStandardLibrarySourceRoot("stdlib");
		compiler.update("Main.hx",
			'import haxeon.wire.JsonWire; import haxeon.wire.MessagePack;
@:wire enum State { @:id(1) Idle; @:id(2) Moving(steps:Array<Int>); }
@:wire class Item { @:id(1) public var name:String; @:id(2) public var state:State; @:id(3) public var note:Null<String>; @:id(4) public var scores:Map<String, Int>; public function new() {} }
@:wire typedef Point = { @:id(1) var x:Float; @:id(2) var y:Float; }
abstract Distance(Float) from Float to Float {}
@:wire typedef Frozen = { @:id(1) var values:haxe.ds.ReadOnlyArray<Int>; @:id(2) @:optional var extra:haxe.ds.ReadOnlyArray<Int>; }
function main():Int {
  var frozen:Frozen = {values: [4, 5], extra: null};
  var frozenJson:Frozen = (JsonWire.decode(JsonWire.encode(frozen)) : Result<Frozen, haxeon.wire.WireError>).unwrap();
  var frozenPacked:Frozen = (MessagePack.decode(MessagePack.encode(frozen)) : Result<Frozen, haxeon.wire.WireError>).unwrap();
  if (frozenJson.values[0] != 4 || frozenPacked.values[1] != 5 || frozenJson.extra != null || frozenPacked.extra != null) return 20;
  frozen.extra = [8];
  var filled:Frozen = (JsonWire.decode(JsonWire.encode(frozen)) : Result<Frozen, haxeon.wire.WireError>).unwrap();
  if (filled.extra[0] != 8) return 21;
  var point:Point = {x: 2.0, y: 3.0};
  var pointAgain:Point = (JsonWire.decode(JsonWire.encode(point)) : Result<Point, haxeon.wire.WireError>).unwrap();
  if (pointAgain.x != 2.0 || pointAgain.y != 3.0) return 17;
  var pointPacked:Point = (MessagePack.decode(MessagePack.encode(point)) : Result<Point, haxeon.wire.WireError>).unwrap();
  if (pointPacked.x != pointAgain.x || pointPacked.y != pointAgain.y) return 18;
  var distance:Distance = 3.5;
  var distanceAgain:Distance = (JsonWire.decode(JsonWire.encode(distance)) : Result<Distance, haxeon.wire.WireError>).unwrap();
  if (distanceAgain != distance) return 19;
  var item = new Item(); item.name = "motor"; item.state = Moving([2, 3]); item.note = null; item.scores = ["b" => 2, "a" => 1];
  var json = JsonWire.encode(item);
  if (json.indexOf("1:name") < 0 || json.indexOf("2:Moving") < 0) return 1;
  var decoded:Item = (JsonWire.decode(json) : Result<Item, haxeon.wire.WireError>).unwrap();
  var packed = MessagePack.encode(item);
  var unpacked:Item = (MessagePack.decode(packed) : Result<Item, haxeon.wire.WireError>).unwrap();
  if (decoded.name != unpacked.name || decoded.note != unpacked.note || decoded.scores.get("a") != 1) return 2;
	  switch (decoded.state) { case Moving(steps): if (steps.length != 2 || steps[0] != 2 || steps[1] != 3) return 13; default: return 14; }
  var idle = new Item(); idle.name = "idle"; idle.state = Idle; idle.note = "ready"; idle.scores = [];
  var idleAgain:Item = (JsonWire.decode(JsonWire.encode(idle)) : Result<Item, haxeon.wire.WireError>).unwrap();
  if (idleAgain.note != "ready" || idleAgain.scores.exists("a")) return 3;
  var older = StringTools.replace(json, "[\\"1:name\\",\\"motor\\"]", "[\\"1:name\\",\\"motor\\"],[99,42]");
	  if (older == json) return 6;
  var unknown:Item = (JsonWire.decode(older) : Result<Item, haxeon.wire.WireError>).unwrap();
  if (unknown.name != "motor") return 4;
	  var absent = StringTools.replace(json, ",[\\"3:note\\",null]", "");
	  if (absent == json) return 7;
	  var withoutOptional:Item = (JsonWire.decode(absent) : Result<Item, haxeon.wire.WireError>).unwrap();
	  if (withoutOptional.note != null) return 8;
	  var withoutRequired = StringTools.replace(json, "[\\"2:state\\",[[\\"2:Moving\\",[[2,3]]]]],", "");
	  if (withoutRequired == json) return 16;
	  var missingRejected = false;
	  try { var missing:Item = (JsonWire.decode(withoutRequired) : Result<Item, haxeon.wire.WireError>).unwrap(); }
	  catch (_:Dynamic) missingRejected = true;
	  if (!missingRejected) return 15;
  var rejected = false;
  try { var wrong:Item = (JsonWire.decode(StringTools.replace(json, "\\"version\\":1", "\\"version\\":2")) : Result<Item, haxeon.wire.WireError>).unwrap(); }
  catch (_:Dynamic) rejected = true;
  if (!rejected) return 5;
  var wide = haxe.Int64.make(0x10203040, 0x50607080);
  var wideAgain:haxe.Int64 = (JsonWire.decode(JsonWire.encode(wide)) : Result<haxe.Int64, haxeon.wire.WireError>).unwrap();
  if (haxe.Int64.compare(wide, wideAgain) != 0) return 9;
  var binary = haxe.io.Bytes.alloc(3); binary.set(0, 65); binary.set(1, 0); binary.set(2, 66);
  var binaryAgain:haxe.io.Bytes = (JsonWire.decode(JsonWire.encode(binary)) : Result<haxe.io.Bytes, haxeon.wire.WireError>).unwrap();
  if (binaryAgain.length != binary.length || binaryAgain.get(1) != 0) return 10;
  var nan:Float = (JsonWire.decode(JsonWire.encode(Math.NaN)) : Result<Float, haxeon.wire.WireError>).unwrap();
  if (!Math.isNaN(nan)) return 11;
	  var onlyJson:Map<Int, String> = [2 => "two", 1 => "one"];
	  var onlyJsonAgain:Map<Int, String> = (JsonWire.decode(JsonWire.encode(onlyJson)) : Result<Map<Int, String>, haxeon.wire.WireError>).unwrap();
	  if (onlyJsonAgain.get(1) != "one") return 12;
  return 42;
}');
		File.saveBytes(Sys.args()[0], compiler.compile("Main").artifact.hashLink().hashLinkBytes().flatten());
	}
}
