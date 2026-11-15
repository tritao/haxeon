package compiler;

/**
 * Arrays allocated at their final size. A comprehension like `[for (_ in blocks) false]` pushes its elements one by one and so
 * copies the array each time it grows; these allocate once.
 */
class Arrays {
	public static function ints(count:Int, value:Int):Array<Int> {
		var result:Array<Int> = [];
		result.resize(count);
		for (index in 0...count)
			result[index] = value;
		return result;
	}

	public static function bools(count:Int, value:Bool):Array<Bool> {
		var result:Array<Bool> = [];
		result.resize(count);
		for (index in 0...count)
			result[index] = value;
		return result;
	}

	/**
	 * `count` references to the same read-only `list`: per-index lists that start out shared and empty, and are replaced by a list
	 * of their own on first use. The type keeps every list read-only; only the code that replaces them writes.
	 */
	public static function shared(count:Int, list:haxe.ds.ReadOnlyArray<Int>):Array<haxe.ds.ReadOnlyArray<Int>> {
		var result:Array<haxe.ds.ReadOnlyArray<Int>> = [];
		result.resize(count);
		for (index in 0...count)
			result[index] = list;
		return result;
	}
}
