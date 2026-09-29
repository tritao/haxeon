package haxeon.wire;

import haxe.crypto.Base64;
import haxe.io.Bytes;

private class JsonWireReadFrame {
	public final values:Array<Dynamic>;
	public final map:Bool;
	public var index:Int = 0;

	public function new(values:Array<Dynamic>, map:Bool) {
		this.values = values;
		this.map = map;
	}

	public function length():Int
		return map ? values.length * 2 : values.length;

	public function at(index:Int):Dynamic {
		if (!map)
			return values[index];
		var pair:Array<Dynamic> = cast values[index >> 1];
		if (pair == null || pair.length != 2)
			throw "Invalid JSON wire map pair";
		return pair[index & 1];
	}
}

/** Bounded JSON reader with the same typed events as MessagePackReader. */
class JsonWireReader {
	final root:Dynamic;
	final maxContainer:Int;
	final maxDepth:Int;
	final frames:Array<JsonWireReadFrame> = [];
	var consumed:Bool = false;

	public function new(source:String, ?maxContainer:Int = 1000000, ?maxDepth:Int = 64, ?maxBytes:Int = 16 * 1024 * 1024) {
		if (source == null || maxContainer < 0 || maxDepth < 0 || maxBytes < 0)
			throw "Invalid JSON wire input or limits";
		if (Bytes.ofString(source).length > maxBytes)
			throw "JSON input exceeds configured limit";
		var envelope:Dynamic = haxe.Json.parse(source);
		if (envelope == null || Reflect.field(envelope, "version") != 1 || !Reflect.hasField(envelope, "value"))
			throw "Unsupported JSON wire version or missing value";
		root = Reflect.field(envelope, "value");
		this.maxContainer = maxContainer;
		this.maxDepth = maxDepth;
	}

	function peek():Dynamic {
		trimCompleted();
		if (frames.length == 0) {
			if (consumed)
				throw "JSON wire value has ended";
			return root;
		}
		var frame = frames[frames.length - 1];
		if (frame.index >= frame.length())
			throw "JSON wire container has ended";
		return frame.at(frame.index);
	}

	function take():Dynamic {
		var value = peek();
		if (frames.length == 0)
			consumed = true;
		else
			frames[frames.length - 1].index++;
		return value;
	}

	function trimCompleted():Void {
		while (frames.length > 0 && frames[frames.length - 1].index == frames[frames.length - 1].length())
			frames.pop();
	}

	function open(map:Bool):Int {
		var value:Dynamic = take();
		if (!Std.isOfType(value, Array))
			throw "Expected JSON wire container";
		var values:Array<Dynamic> = cast value;
		if (values.length > maxContainer)
			throw "JSON wire container exceeds configured limit";
		if (frames.length >= maxDepth)
			throw "JSON wire nesting exceeds configured limit";
		if (values.length > 0)
			frames.push(new JsonWireReadFrame(values, map));
		return values.length;
	}

	public function atEnd():Bool {
		trimCompleted();
		return consumed && frames.length == 0;
	}

	public function isNil():Bool
		return peek() == null;

	public function readNil():Void
		if (take() != null)
			throw "Expected JSON null";

	public function readBool():Bool {
		var value = take();
		if (!Std.isOfType(value, Bool))
			throw "Expected JSON boolean";
		return cast value;
	}

	public function readInt():Int {
		var value = take();
		if (Std.isOfType(value, String)) {
			var key:String = cast value;
			var colon = key.indexOf(":");
			if (colon >= 0)
				key = key.substr(0, colon);
			var parsed = Std.parseInt(key);
			if (parsed == null)
				throw "Expected JSON wire integer key";
			return parsed;
		}
		if (!Std.isOfType(value, Int))
			throw "Expected JSON integer";
		return cast value;
	}

	public function readInt64():haxe.Int64 {
		var value:Dynamic = take();
		if (Std.isOfType(value, Int))
			return haxe.Int64.ofInt(cast value);
		if (!Std.isOfType(value, String))
			throw "Expected JSON Int64";
		var encoded:String = cast value;
		if (!StringTools.startsWith(encoded, "i64:"))
			throw "Expected JSON Int64";
		return haxe.Int64.parseString(encoded.substr(4));
	}

	public function readFloat():Float {
		var value:Dynamic = take();
		if (Std.isOfType(value, String)) {
			return switch (cast value : String) {
				case "float:NaN": Math.NaN;
				case "float:+Infinity": Math.POSITIVE_INFINITY;
				case "float:-Infinity": Math.NEGATIVE_INFINITY;
				default: throw "Expected JSON float";
			};
		}
		if (!Std.isOfType(value, Float) && !Std.isOfType(value, Int))
			throw "Expected JSON float";
		return cast value;
	}

	public function readString():String {
		var value = take();
		if (!Std.isOfType(value, String))
			throw "Expected JSON string";
		return cast value;
	}

	public function readBinary():Bytes {
		var encoded = readString();
		if (!StringTools.startsWith(encoded, "base64:"))
			throw "Expected JSON binary";
		return Base64.decode(encoded.substr(7));
	}

	public function readArrayHeader():Int
		return open(false);

	public function readMapHeader():Int
		return open(true);

	public function skip():Void {
		take();
	}
}
