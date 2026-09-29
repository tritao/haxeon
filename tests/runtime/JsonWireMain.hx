import compiler.Compiler;
import compiler.hl.HlWriter;
import compiler.runtime.CompilerIntrinsics;
import sys.io.File;

/** Builds a native JSON wire round-trip fixture using the compiler under test. */
class JsonWireMain {
	static function main():Void {
		var compiler = new Compiler();
		CompilerIntrinsics.register(compiler);
		compiler.addSourceRoot("stdlib");
		compiler.update("Main.hx", 'import haxeon.wire.JsonWire; import haxeon.wire.MessagePack;
@:wire enum State { @:id(1) Idle; @:id(2) Moving(steps:Array<Int>); }
@:wire class Item { @:id(1) public var name:String; @:id(2) public var state:State; @:id(3) public var note:Null<String>; @:id(4) public var scores:Map<String, Int>; public function new() {} }
function main():Int {
  var item = new Item(); item.name = "motor"; item.state = Moving([2, 3]); item.note = null; item.scores = ["b" => 2, "a" => 1];
  var json = JsonWire.encode(item);
  if (json.indexOf("1:name") < 0 || json.indexOf("2:Moving") < 0) return 1;
  var decoded:Item = JsonWire.decode(json);
  var packed = MessagePack.encode(item);
  var unpacked:Item = MessagePack.decode(packed);
  if (decoded.name != unpacked.name || decoded.note != unpacked.note || decoded.scores.get("a") != 1) return 2;
	  switch (decoded.state) { case Moving(steps): if (steps.length != 2 || steps[0] != 2 || steps[1] != 3) return 13; default: return 14; }
  var idle = new Item(); idle.name = "idle"; idle.state = Idle; idle.note = "ready"; idle.scores = [];
  var idleAgain:Item = JsonWire.decode(JsonWire.encode(idle));
  if (idleAgain.note != "ready" || idleAgain.scores.exists("a")) return 3;
  var older = StringTools.replace(json, "[\\"1:name\\",\\"motor\\"]", "[\\"1:name\\",\\"motor\\"],[99,42]");
	  if (older == json) return 6;
  var unknown:Item = JsonWire.decode(older);
  if (unknown.name != "motor") return 4;
	  var absent = StringTools.replace(json, ",[\\"3:note\\",null]", "");
	  if (absent == json) return 7;
	  var withoutOptional:Item = JsonWire.decode(absent);
	  if (withoutOptional.note != null) return 8;
	  var withoutRequired = StringTools.replace(json, "[\\"2:state\\",[[\\"2:Moving\\",[[2,3]]]]],", "");
	  if (withoutRequired == json) return 16;
	  var missingRejected = false;
	  try { var missing:Item = JsonWire.decode(withoutRequired); }
	  catch (_:Dynamic) missingRejected = true;
	  if (!missingRejected) return 15;
  var rejected = false;
  try { var wrong:Item = JsonWire.decode(StringTools.replace(json, "\\"version\\":1", "\\"version\\":2")); }
  catch (_:Dynamic) rejected = true;
  if (!rejected) return 5;
  var wide = haxe.Int64.make(0x10203040, 0x50607080);
  var wideAgain:haxe.Int64 = JsonWire.decode(JsonWire.encode(wide));
  if (haxe.Int64.compare(wide, wideAgain) != 0) return 9;
  var binary = haxe.io.Bytes.alloc(3); binary.set(0, 65); binary.set(1, 0); binary.set(2, 66);
  var binaryAgain:haxe.io.Bytes = JsonWire.decode(JsonWire.encode(binary));
  if (binaryAgain.length != binary.length || binaryAgain.get(1) != 0) return 10;
  var nan:Float = JsonWire.decode(JsonWire.encode(Math.NaN));
  if (!Math.isNaN(nan)) return 11;
	  var onlyJson:Map<Int, String> = [2 => "two", 1 => "one"];
	  var onlyJsonAgain:Map<Int, String> = JsonWire.decode(JsonWire.encode(onlyJson));
	  if (onlyJsonAgain.get(1) != "one") return 12;
  return 42;
}');
		File.saveBytes(Sys.args()[0], HlWriter.encode(compiler.compile("Main").module));
	}
}
