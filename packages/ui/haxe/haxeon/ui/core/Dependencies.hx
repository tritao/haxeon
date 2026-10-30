package haxeon.ui.core;

/**
 * What a build read outside widget state, recorded by BuildContext.observeInt and observeString: for each read, how to read
 * it again and the value it gave. A retained subtree is current while every read still gives the same value. Reads are
 * polled, so a value without change notification (a command predicate, a model field) is covered as well as one that has a
 * revision.
 */
class Dependencies {
	final intReads:Array<Void->Int>;
	final intValues:Array<Int>;
	final stringReads:Array<Void->Null<String>>;
	final stringValues:Array<Null<String>>;

	public function new() {
		intReads = [];
		intValues = [];
		stringReads = [];
		stringValues = [];
	}

	public var intCount(get, never):Int;
	inline function get_intCount():Int
		return intReads.length;

	public var stringCount(get, never):Int;
	inline function get_stringCount():Int
		return stringReads.length;

	public function addInt(read:Void->Int, value:Int):Void {
		intReads.push(read);
		intValues.push(value);
	}

	public function addString(read:Void->Null<String>, value:Null<String>):Void {
		stringReads.push(read);
		stringValues.push(value);
	}

	/** Appends `other`'s reads, as when a retained subtree inside a recording one is reused. */
	public function addAll(other:Dependencies):Void {
		for (index in 0...other.intReads.length)
			addInt(other.intReads[index], other.intValues[index]);
		for (index in 0...other.stringReads.length)
			addString(other.stringReads[index], other.stringValues[index]);
	}

	/** The reads recorded after the given counts, as a separate set. */
	public function since(intMark:Int, stringMark:Int):Dependencies {
		var result = new Dependencies();
		for (index in intMark...intReads.length)
			result.addInt(intReads[index], intValues[index]);
		for (index in stringMark...stringReads.length)
			result.addString(stringReads[index], stringValues[index]);
		return result;
	}

	/** Whether every read still gives the value it gave when recorded. */
	public function current():Bool {
		for (index in 0...intReads.length)
			if (intReads[index]() != intValues[index])
				return false;
		for (index in 0...stringReads.length)
			if (stringReads[index]() != stringValues[index])
				return false;
		return true;
	}

	/** Reads below a self-updating boundary are checked through that boundary's current build. */
	public function truncate(intMark:Int, stringMark:Int):Void {
		intReads.resize(intMark);
		intValues.resize(intMark);
		stringReads.resize(stringMark);
		stringValues.resize(stringMark);
	}

	public function clear():Void {
		intReads.resize(0);
		intValues.resize(0);
		stringReads.resize(0);
		stringValues.resize(0);
	}
}
