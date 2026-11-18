package compiler.syntax;

import haxe.io.Bytes;

/**
 * Identifier names, one `String` per distinct name: a name read again is found from its bytes, without making a string.
 * Names outlive the syntax they are read from (they become the names of fields, functions and types), so sharing them
 * keeps one copy alive instead of one per occurrence. Identifiers are ASCII, so a name's bytes are its characters.
 */
class NameTable {
	var names:Array<Null<String>>;
	var hashes:Array<Int>;
	var mask:Int;
	var count = 0;

	public function new() {
		allocate(4096);
	}

	/** The name spelled by `source`'s bytes from `start` to `end`, made the first time it is read. */
	public function intern(source:Bytes, start:Int, end:Int):String {
		var hash = 0x811c9dc5;
		for (index in start...end)
			hash = (hash ^ source.get(index)) * 0x01000193;
		var slot = hash & mask;
		while (true) {
			var name = names[slot];
			if (name == null)
				break;
			if (hashes[slot] == hash && spells(name, source, start, end))
				return name;
			slot = (slot + 1) & mask;
		}
		var name = source.getString(start, end - start);
		names[slot] = name;
		hashes[slot] = hash;
		count++;
		if (count * 2 > mask)
			grow();
		return name;
	}

	static function spells(name:String, source:Bytes, start:Int, end:Int):Bool {
		if (name.length != end - start)
			return false;
		for (index in 0...name.length)
			if (StringTools.fastCodeAt(name, index) != source.get(start + index))
				return false;
		return true;
	}

	function allocate(size:Int):Void {
		names = [for (_ in 0...size) null];
		hashes = [for (_ in 0...size) 0];
		mask = size - 1;
	}

	function grow():Void {
		var oldNames = names, oldHashes = hashes;
		allocate(oldNames.length * 2);
		for (index in 0...oldNames.length) {
			var name = oldNames[index];
			if (name == null)
				continue;
			var slot = oldHashes[index] & mask;
			while (names[slot] != null)
				slot = (slot + 1) & mask;
			names[slot] = name;
			hashes[slot] = oldHashes[index];
		}
	}
}
