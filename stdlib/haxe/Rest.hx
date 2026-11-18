package haxe;

/**
	The arguments a rest parameter (`function f(...values:Int)`) receives: `values[0]`, `values.length`, `for (value in
	values)`, as Haxe's `haxe.Rest`. A call passes them packed in an array (`f(1, 2, 3)`), or passes an array as they are
	(`f(...array)`, `Rest.of(array)`), which the rest then shares, as on Haxe's targets.
**/
@:forward(length, iterator)
@:arrayAccess
abstract Rest<T>(Array<T>) from Array<T> {
	/** The rest arguments `array` holds; changing `array` afterwards changes them too. */
	public static function of<T>(array:Array<T>):Rest<T>
		return array;

	/** A new Array of the arguments. */
	@:to public function toArray():Array<T>
		return this.copy();

	/** New rest arguments: these, then `item`. */
	public function append(item:T):Rest<T> {
		var result = this.copy();
		result.push(item);
		return result;
	}

	/** New rest arguments: `item`, then these. */
	public function prepend(item:T):Rest<T> {
		var result = this.copy();
		result.unshift(item);
		return result;
	}

	public function toString():String
		return Std.string(this);
}
