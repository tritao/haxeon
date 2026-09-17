import haxe.io.Bytes;
import haxeon.wire.MessagePackReader;

function main():Int {
	if (!rejects(function() new MessagePackReader(raw([0xd3, 0x00])).readInt64()))
		return 1;
	if (!rejects(function() new MessagePackReader(raw([0xc1])).skip()))
		return 2;
	if (!rejects(function() new MessagePackReader(raw([0xd4])).readExtension()))
		return 3;
	if (!rejects(function() new MessagePackReader(raw([0xdd, 0xff, 0xff, 0xff, 0xff])).skip()))
		return 4;

	var deep = Bytes.alloc(10);
	for (index in 0...9)
		deep.set(index, 0x91);
	deep.set(9, 0xc0);
	if (!rejects(function() new MessagePackReader(deep, 100, 4).skip()))
		return 5;

	var valid = new MessagePackReader(raw([0x81, 0xa1, 0x61, 0x92, 0x01, 0xc0]));
	valid.skip();
	if (!valid.atEnd())
		return 6;

	for (seed in 0...256) {
		var bytes = Bytes.alloc(1 + seed % 13),
			state = seed * 1103515245 + 12345;
		for (index in 0...bytes.length) {
			state = state * 1664525 + 1013904223;
			bytes.set(index, (state >>> 24) & 0xff);
		}
		try {
			var reader = new MessagePackReader(bytes);
			reader.skip();
			if (reader.position() < 0 || reader.position() > bytes.length)
				return 7;
		} catch (_:Dynamic) {}
	}
	return 42;
}

function rejects(action:Void->Void):Bool {
	try {
		action();
		return false;
	} catch (_:Dynamic) {
		return true;
	}
}

function raw(values:Array<Int>):Bytes {
	var bytes = Bytes.alloc(values.length);
	for (index in 0...values.length)
		bytes.set(index, values[index]);
	return bytes;
}
