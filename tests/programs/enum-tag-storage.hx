enum Mode implements Hashable { Off; On; Paused; }
enum OtherMode { Other; }
enum Phantom<T> { Present; Missing; }
enum Carrier { Wrap(mode:Mode); More(next:Carrier); }

struct TaggedPair {
	public var mode:Mode;
	public var count:Int;
	public function new(mode:Mode, count:Int) { this.mode = mode; this.count = count; }
}

class Holder {
	public var mode:Mode;
	public var optional:Null<Mode>;
	public function new(mode:Mode) { this.mode = mode; optional = null; }
	public function read():Mode return mode;
	public function write(value:Mode):Void mode = value;
}

interface DynamicSinkBase { function accept(value:Dynamic):Dynamic; }
interface DynamicSink extends DynamicSinkBase {}
class SinkBase {
	public var saved:Dynamic;
	public function new() saved = null;
	public function accept(value:Dynamic):Dynamic { saved = value; return value; }
}
class Sink extends SinkBase implements DynamicSink {
	public function new() super();
}

class Box<T> {
	public var value:T;
	public function new(value:T) this.value = value;
	public function get():T return value;
}

#if hl
@:hlNative("std", "enum_parameters") extern function enumParameters(value:Dynamic):Array<Dynamic>;
#end

function through(value:Mode):Mode return value;

class Probe {
	static var holder:Holder;
	static var values:Array<Mode>;
	static var byName:Map<String,Mode>;
	@:expose public static function prepare():Void {
		holder = new Holder(Off);
		values = [Off, On, Paused];
		byName = new Map(); byName.set("current", Off);
	}
	@:expose public static function allocateArray(count:Int):Int {
		values = [];
		values.resize(count);
		for (index in 0...count) values[index] = On;
		return values.length;
	}
	@:expose public static function perform(count:Int):Int {
		var sum = 0;
		for (index in 0...count) {
			var value = (index & 1) == 0 ? Off : On;
			holder.write(value); holder.optional = value; values[index & 1] = value;
			byName.set("current", value); if (byName.get("current") != value) return -3;
			var pair = new TaggedPair(value, 42);
			if (holder.read() != values[index & 1] || holder.optional != value || pair.mode != value) return -1;
			var dynamicValue:Dynamic = value;
			var roundtrip:Mode = cast dynamicValue;
			if (roundtrip != value || Type.enumIndex(value) != (index & 1)) return -2;
			sum += pair.count;
		}
		return sum;
	}
}

function main():Int {
	if (sizeof<TaggedPair>() != 8 || alignof<TaggedPair>() != 4 || offsetof<TaggedPair>("count") != 4) return 1;
	Probe.prepare();
	if (Probe.perform(8) != 336) return 2;
	var records:Array<TaggedPair> = [new TaggedPair(Off, 1), new TaggedPair(On, 2)];
	var copied = records[0]; records[0].mode = Paused;
	if (copied.mode != Off || records[0].mode != Paused || records[1].mode != On) return 24;
	var root:Dynamic = {leaf: new Holder(Off)};
	var leaf:Dynamic = Reflect.field(root, "leaf");
	var before:Mode = cast Reflect.field(leaf, "mode");
	if (before != Off) return 3;
	Reflect.setField(leaf, "mode", On);
	var after:Mode = cast Reflect.field(leaf, "mode");
	if (after != On) return 4;
	Reflect.setField(leaf, "optional", null);
	var optional:Null<Mode> = cast Reflect.field(leaf, "optional");
	if (optional != null) return 5;
	var rejected = false;
	try { Reflect.setField(leaf, "mode", Other); } catch (_:Dynamic) { rejected = true; }
	if (!rejected) return 6;
	rejected = false;
	try { var bad:Dynamic = 1; var checked:Mode = cast bad; } catch (_:Dynamic) { rejected = true; }
	if (!rejected) return 7;
	var fields = Reflect.fields(leaf); fields.sort(Reflect.compare);
	if (fields.join(",") != "mode,optional") return 8;
	var list:Array<Mode> = [Off, On, Paused];
	list.push(On); list.insert(1, Paused); list.reverse();
	var found = 0;
	var cursor = list.iterator();
	while (cursor.hasNext()) switch cursor.next() { case Off: found += 1; case On: found += 2; case Paused: found += 4; }
	if (found != 13) return 9;
	var erasedArray:Dynamic = list;
	var restoredArray:Array<Mode> = cast erasedArray;
	if (restoredArray.length != 5 || restoredArray[0] != On) return 18;
	var reflectedArrayRoot:Dynamic = {values:list};
	var reflectedArray:Array<Mode> = cast Reflect.field(reflectedArrayRoot, "values");
	if (reflectedArray[0] != On) return 19;
	rejected = false;
	try { var integers:Array<Int> = cast erasedArray; } catch (_:Dynamic) { rejected = true; }
	if (!rejected) return 23;
	if (list.pop() != Off || list.shift() != On) return 15;
	var empty:Array<Mode> = [];
	if (empty.pop() != null || empty.shift() != null) return 16;
	var anon:Dynamic = {mode:Off};
	var anonBefore:Mode = cast Reflect.field(anon, "mode");
	Reflect.setField(anon, "mode", Paused);
	var anonAfter:Mode = cast Reflect.field(anon, "mode");
	if (anonBefore != Off || anonAfter != Paused || Reflect.fields(anon).join(",") != "mode") return 17;
	if (Std.string(On) != "On") return 10;
	var callback:Mode->Mode = through;
	if (callback(On) != On) return 11;
	var erased:Dynamic = callback;
	var restored:Mode->Mode = cast erased;
	if (restored(Paused) != Paused) return 12;
	var dynamicallyReturned:Mode = cast erased(Off);
	if (dynamicallyReturned != Off) return 14;
	rejected = false;
	try { var wrongSignature:Int->Int = cast erased; wrongSignature(1); } catch (_:Dynamic) { rejected = true; }
	if (!rejected) return 29;
	rejected = false;
	try { var wrongEnumSignature:OtherMode->OtherMode = cast erased; wrongEnumSignature(Other); } catch (_:Dynamic) { rejected = true; }
	if (!rejected) return 30;
	var box = new Box<Mode>(Off);
	if (box.get() != Off) return 13;
	var sink:DynamicSink = new Sink();
	var fromInterface:Mode = cast sink.accept(Paused);
	if (fromInterface != Paused) return 20;
	var concrete = new Sink();
	var fromInherited:Mode = cast concrete.accept(On);
	concrete.saved = Paused;
	var fromField:Mode = cast concrete.saved;
	if (fromInherited != On || fromField != Paused) return 31;
	var phantom:Phantom<Int> = Present;
	var erasedPhantom:Dynamic = phantom;
	var restoredPhantom:Phantom<Int> = cast erasedPhantom;
	if (restoredPhantom != Present) return 21;
	rejected = false;
	try { var wrongPhantom:Phantom<String> = cast erasedPhantom; } catch (_:Dynamic) { rejected = true; }
	if (!rejected) return 22;
	var carrier = Wrap(On);
	#if hl
	// HashLink formats boxed payloads from native type metadata; Wasm currently formats only nullary cases.
	if (Std.string(carrier) != "Wrap(On)") return 25;
	var parameters = enumParameters(carrier);
	var parameter:Mode = cast parameters[0];
	if (parameter != On || Std.string(parameters[0]) != "On") return 28;
	#end
	switch carrier { case Wrap(mode): if (mode != On) return 26; case More(_): return 27; }
	return 42;
}
