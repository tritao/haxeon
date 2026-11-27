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
			throw new WireFailure(Malformed("Invalid JSON wire map pair"));
		return pair[index & 1];
	}
}

/** Reads one value from the JSON wire envelope event by event, as `MessagePackReader` reads MessagePack, within limits. */
class JsonWireReader {
	final root:Dynamic;
	final maxContainer:Int;
	final maxDepth:Int;
	final frames:Array<JsonWireReadFrame> = [];
	var consumed:Bool = false;

	/**
	 * A reader of the JSON wire envelope `source`, `{"version": 1, "value": ...}`, refusing more than `maxContainer`
	 * items in a container, `maxDepth` levels of nesting, or `maxBytes` bytes of text. It fails the decode with a
	 * `WireFailure` when `source` is not such an envelope or is over the limit.
	 */
	public function new(source:String, ?maxContainer:Int = 1000000, ?maxDepth:Int = 64,
			?maxBytes:Int = 16 * 1024 * 1024) {
		if (source == null || maxContainer < 0 || maxDepth < 0 || maxBytes < 0)
			throw new haxe.Exception("Invalid JSON wire input or limits");
		if (Bytes.ofString(source).length > maxBytes)
			throw new WireFailure(LimitExceeded("JSON input exceeds configured limit"));
		var envelope:Dynamic;
		try
			envelope = haxe.Json.parse(source)
		catch (error:Dynamic)
			throw new WireFailure(Malformed('Invalid JSON: ${Std.string(error)}'));
		if (envelope == null || Reflect.field(envelope, "version") != 1 || !Reflect.hasField(envelope, "value"))
			throw new WireFailure(Malformed("Unsupported JSON wire version or missing value"));
		root = Reflect.field(envelope, "value");
		this.maxContainer = maxContainer;
		this.maxDepth = maxDepth;
	}

	function peek():Dynamic {
		trimCompleted();
		if (frames.length == 0) {
			if (consumed)
				throw new WireFailure(Malformed("JSON wire value has ended"));
			return root;
		}
		var frame = frames[frames.length - 1];
		if (frame.index >= frame.length())
			throw new WireFailure(Malformed("JSON wire container has ended"));
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
			throw new WireFailure(Malformed("Expected JSON wire container"));
		var values:Array<Dynamic> = cast value;
		return pushFrame(values, map);
	}

	/**
	 * Enters the object that comes next, and returns how many fields it has: each is read as its name, then its value.
	 * It fails the decode with a `WireFailure` when what comes next is not an object.
	 */
	public function readObjectHeader():Int {
		var value = take();
		if (!isObjectValue(value))
			throw new WireFailure(Malformed("Expected JSON wire object"));
		var names = Reflect.fields(value);
		if (names.length > maxContainer)
			throw new WireFailure(LimitExceeded("JSON wire container exceeds configured limit"));
		var pairs:Array<Dynamic> = [];
		for (name in names)
			pairs.push([name, Reflect.field(value, name)]);
		return pushFrame(pairs, true);
	}

	function pushFrame(values:Array<Dynamic>, map:Bool):Int {
		if (values.length > maxContainer)
			throw new WireFailure(LimitExceeded("JSON wire container exceeds configured limit"));
		if (frames.length >= maxDepth)
			throw new WireFailure(LimitExceeded("JSON wire nesting exceeds configured limit"));
		if (values.length > 0)
			frames.push(new JsonWireReadFrame(values, map));
		return values.length;
	}

	/** Whether the whole value has been read. */
	public function atEnd():Bool {
		trimCompleted();
		return consumed && frames.length == 0;
	}

	/** Fails the decode with `TrailingData` unless the value is consumed: a decoded value must be the whole input. */
	public function requireEnd():Void {
		if (!atEnd())
			throw new WireFailure(TrailingData);
	}

	/** Whether what comes next is null. */
	public function isNil():Bool
		return peek() == null;

	/** Whether what comes next is a string. */
	public function isString():Bool
		return Std.isOfType(peek(), String);

	/** Whether what comes next is an object. */
	public function isObject():Bool
		return isObjectValue(peek());

	function isObjectValue(value:Dynamic):Bool
		return Reflect.isObject(value) && !Std.isOfType(value, String) && !Std.isOfType(value, Array);

	/** Reads a null; fails the decode with a `WireFailure` when what comes next is not one. */
	public function readNil():Void
		if (take() != null)
			throw new WireFailure(Malformed("Expected JSON null"));

	/** Reads a boolean; fails the decode with a `WireFailure` when what comes next is not one. */
	public function readBool():Bool {
		var value = take();
		if (!Std.isOfType(value, Bool))
			throw new WireFailure(Malformed("Expected JSON boolean"));
		return cast value;
	}

	/** Reads an integer; fails the decode with a `WireFailure` when what comes next is not one. */
	public function readInt():Int {
		var value = take();
		if (Std.isOfType(value, String)) {
			var key:String = cast value;
			var colon = key.indexOf(":");
			if (colon >= 0)
				key = key.substr(0, colon);
			var parsed = Std.parseInt(key);
			if (parsed == null)
				throw new WireFailure(Malformed("Expected JSON wire integer key"));
			return parsed;
		}
		if (!Std.isOfType(value, Int))
			throw new WireFailure(Malformed("Expected JSON integer"));
		return cast value;
	}

	/**
	 * Reads a 64-bit integer: a JSON integer, or a string `"i64:..."` for one past the `Int` range. It fails the decode
	 * with a `WireFailure` when what comes next is neither.
	 */
	public function readInt64():haxe.Int64 {
		var value:Dynamic = take();
		if (Std.isOfType(value, Int))
			return haxe.Int64.ofInt(cast value);
		if (!Std.isOfType(value, String))
			throw new WireFailure(Malformed("Expected JSON Int64"));
		var encoded:String = cast value;
		if (!StringTools.startsWith(encoded, "i64:"))
			throw new WireFailure(Malformed("Expected JSON Int64"));
		return haxe.Int64.parseString(encoded.substr(4));
	}

	/**
	 * Reads a number, or `"float:NaN"`, `"float:+Infinity"` or `"float:-Infinity"`; fails the decode with a
	 * `WireFailure` when what comes next is none of these.
	 */
	public function readFloat():Float {
		var value:Dynamic = take();
		if (Std.isOfType(value, String)) {
			return switch (cast value:String) {
				case "float:NaN": Math.NaN;
				case "float:+Infinity": Math.POSITIVE_INFINITY;
				case "float:-Infinity": Math.NEGATIVE_INFINITY;
				default: throw new WireFailure(Malformed("Expected JSON float"));
			};
		}
		if (!Std.isOfType(value, Float) && !Std.isOfType(value, Int))
			throw new WireFailure(Malformed("Expected JSON float"));
		return cast value;
	}

	/** Reads a string; fails the decode with a `WireFailure` when what comes next is not one. */
	public function readString():String {
		var value = take();
		if (!Std.isOfType(value, String))
			throw new WireFailure(Malformed("Expected JSON string"));
		return cast value;
	}

	/**
	 * Reads bytes, written as a string `"base64:..."`; fails the decode with a `WireFailure` when what comes next is
	 * not one.
	 */
	public function readBinary():Bytes {
		var encoded = readString();
		if (!StringTools.startsWith(encoded, "base64:"))
			throw new WireFailure(Malformed("Expected JSON binary"));
		return Base64.decode(encoded.substr(7));
	}

	/**
	 * Enters the array that comes next, and returns how many items it has; fails the decode with a `WireFailure` when
	 * what comes next is not an array.
	 */
	public function readArrayHeader():Int
		return open(false);

	/**
	 * Enters the map that comes next, written as an array of `[key, value]` pairs, and returns how many entries it has;
	 * each is read as its key, then its value.
	 */
	public function readMapHeader():Int
		return open(true);

	/** Skips what comes next, with all it contains. */
	public function skip():Void {
		take();
	}
}
