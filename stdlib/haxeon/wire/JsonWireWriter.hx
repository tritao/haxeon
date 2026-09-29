package haxeon.wire;

import haxe.crypto.Base64;
import haxe.io.Bytes;

private class JsonWireWriteFrame {
	public final values:Array<Dynamic>;
	public final map:Bool;
	public var remaining:Int;
	public var key:Dynamic;
	public var hasKey:Bool;

	public function new(values:Array<Dynamic>, map:Bool, count:Int) {
		this.values = values;
		this.map = map;
		this.remaining = map ? count * 2 : count;
		this.hasKey = false;
	}
}

/** Event writer used by generated JSON value codecs. */
class JsonWireWriter {
	final maxBytes:Int;
	final frames:Array<JsonWireWriteFrame> = [];
	var root:Dynamic;
	var hasRoot:Bool = false;

	public function new(?maxBytes:Int = 16 * 1024 * 1024) {
		if (maxBytes < 0)
			throw "JSON writer limit cannot be negative";
		this.maxBytes = maxBytes;
	}

	function add(value:Dynamic):Void {
		if (frames.length == 0) {
			if (hasRoot)
				throw "JSON writer has more than one root value";
			root = value;
			hasRoot = true;
			return;
		}
		var frame = frames[frames.length - 1];
		if (frame.remaining <= 0)
			throw "JSON container is full";
		if (frame.map) {
			if (!frame.hasKey) {
				frame.key = value;
				frame.hasKey = true;
			} else {
				frame.values.push([frame.key, value]);
				frame.hasKey = false;
			}
		} else
			frame.values.push(value);
		frame.remaining--;
		while (frames.length > 0 && frames[frames.length - 1].remaining == 0)
			frames.pop();
	}

	public function writeNil():Void
		add(null);

	public function writeBool(value:Bool):Void
		add(value);

	public function writeInt(value:Int):Void
		add(value);

	public function writeInt64(value:haxe.Int64):Void
		add("i64:" + haxe.Int64.toStr(value));

	public function writeFloat(value:Float):Void {
		if (Math.isNaN(value))
			add("float:NaN");
		else if (value == Math.POSITIVE_INFINITY)
			add("float:+Infinity");
		else if (value == Math.NEGATIVE_INFINITY)
			add("float:-Infinity");
		else
			add(value);
	}

	public function writeString(value:String):Void {
		if (value == null)
			throw "JSON wire string cannot be null; writeNil instead";
		add(value);
	}

	public function writeBinary(value:Bytes):Void {
		if (value == null)
			throw "JSON wire binary value cannot be null; writeNil instead";
		add("base64:" + Base64.encode(value));
	}

	public function writeFieldKey(id:Int, name:String):Void
		add(Std.string(id) + ":" + name);

	public function writeArrayHeader(count:Int):Void
		open(count, false);

	public function writeMapHeader(count:Int):Void
		open(count, true);

	function open(count:Int, map:Bool):Void {
		if (count < 0 || count > 1000000)
			throw "JSON container count exceeds limit";
		var values:Array<Dynamic> = [];
		add(values);
		if (count > 0)
			frames.push(new JsonWireWriteFrame(values, map, count));
	}

	public function getString():String {
		if (!hasRoot || frames.length != 0)
			throw "JSON value is incomplete";
		var result = haxe.Json.stringify({version: 1, value: root});
		if (Bytes.ofString(result).length > maxBytes)
			throw "JSON output exceeds configured limit";
		return result;
	}
}
