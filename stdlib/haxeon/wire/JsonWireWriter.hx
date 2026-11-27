package haxeon.wire;

import haxe.crypto.Base64;
import haxe.io.Bytes;

private enum abstract JsonWireContainer(Int) {
	var ArrayValues;
	var MapPairs;
	var ObjectMembers;
}

private class JsonWireWriteFrame {
	public final kind:JsonWireContainer;
	public final size:Int;
	public var remaining:Int;

	public function new(kind:JsonWireContainer, size:Int) {
		this.kind = kind;
		this.size = size;
		this.remaining = size;
	}
}

/** Event writer used by generated JSON value codecs. */
class JsonWireWriter {
	final maxBytes:Int;
	final output = new StringBuf();
	final frames:Array<JsonWireWriteFrame> = [];
	var hasRoot:Bool = false;

	public function new(?maxBytes:Int = 16 * 1024 * 1024) {
		if (maxBytes < 0)
			throw new haxe.Exception("JSON writer limit cannot be negative");
		this.maxBytes = maxBytes;
		output.add('{"version":1,"value":');
	}

	function beginValue(stringValue:Bool):Void {
		if (frames.length == 0) {
			if (hasRoot)
				throw new haxe.Exception("JSON writer has more than one root value");
			hasRoot = true;
			return;
		}
		var frame = frames[frames.length - 1];
		switch frame.kind {
			case ArrayValues:
				if (frame.remaining != frame.size)
					output.add(",");
			case MapPairs, ObjectMembers:
				if (frame.remaining % 2 == 0) {
					if (frame.kind == ObjectMembers && !stringValue)
						throw new haxe.Exception("JSON object key must be a string");
					if (frame.remaining != frame.size)
						output.add(",");
					if (frame.kind == MapPairs)
						output.add("[");
				} else
					output.add(frame.kind == ObjectMembers ? ":" : ",");
		}
		frame.remaining--;
	}

	function endValue():Void {
		while (frames.length > 0) {
			var frame = frames[frames.length - 1];
			if (frame.kind == MapPairs && frame.remaining % 2 == 0)
				output.add("]");
			if (frame.remaining != 0)
				return;
			output.add(frame.kind == ObjectMembers ? "}" : "]");
			frames.pop();
		}
	}

	function writeLiteral(value:String):Void {
		beginValue(false);
		output.add(value);
		endValue();
	}

	public function writeNil():Void
		writeLiteral("null");

	public function writeBool(value:Bool):Void
		writeLiteral(value ? "true" : "false");

	public function writeInt(value:Int):Void
		writeLiteral(Std.string(value));

	public function writeInt64(value:haxe.Int64):Void
		writeString("i64:" + haxe.Int64.toStr(value));

	public function writeFloat(value:Float):Void {
		if (Math.isNaN(value))
			writeString("float:NaN");
		else if (value == Math.POSITIVE_INFINITY)
			writeString("float:+Infinity");
		else if (value == Math.NEGATIVE_INFINITY)
			writeString("float:-Infinity");
		else
			writeLiteral(Std.string(value));
	}

	public function writeString(value:String):Void {
		if (value == null)
			throw new haxe.Exception("JSON wire string cannot be null; writeNil instead");
		beginValue(true);
		output.add('"');
		var start = 0;
		for (index in 0...value.length) {
			var code = value.charCodeAt(index),
				escaped:Null<String> = switch code {
					case 34: '\\"';
					case 92: '\\\\';
					case 8: '\\b';
					case 9: '\\t';
					case 10: '\\n';
					case 12: '\\f';
					case 13: '\\r';
					default: code < 32 ? '\\u00' + StringTools.hex(code, 2) : null;
				};
			if (escaped == null)
				continue;
			output.addSub(value, start, index - start);
			output.add(escaped);
			start = index + 1;
		}
		output.addSub(value, start, value.length - start);
		output.add('"');
		endValue();
	}

	public function writeBinary(value:Bytes):Void {
		if (value == null)
			throw new haxe.Exception("JSON wire binary value cannot be null; writeNil instead");
		writeString("base64:" + Base64.encode(value));
	}

	public function writeFieldKey(id:Int, name:String):Void
		writeString(Std.string(id) + ":" + name);

	public function writeArrayHeader(count:Int):Void
		open(count, ArrayValues);

	public function writeMapHeader(count:Int):Void
		open(count, MapPairs);

	public function writeObjectHeader(count:Int):Void
		open(count, ObjectMembers);

	function open(count:Int, kind:JsonWireContainer):Void {
		if (count < 0 || count > 1000000)
			throw new haxe.Exception("JSON container count exceeds limit");
		beginValue(false);
		output.add(kind == ObjectMembers ? "{" : "[");
		if (count == 0) {
			output.add(kind == ObjectMembers ? "}" : "]");
			endValue();
		} else
			frames.push(new JsonWireWriteFrame(kind, kind == ArrayValues ? count : count * 2));
	}

	public function getString():String {
		if (!hasRoot || frames.length != 0)
			throw new haxe.Exception("JSON value is incomplete");
		var result = output.toString() + "}";
		if (Bytes.ofString(result).length > maxBytes)
			throw new haxe.Exception("JSON output exceeds configured limit");
		return result;
	}
}
