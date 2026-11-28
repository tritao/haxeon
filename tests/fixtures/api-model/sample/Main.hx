package sample;

import sample.Main.Choice;
import sample.Main.Item;
import sample.Main.Reader;

/** Consumer interface. */
@:noCompletion
interface Reader<T> {
	var value(get, never):T;
	function read(?count:Int):T;
}

interface InternalContract {
	private function hidden():Void;
}

class Base {
	public function new() {}

	/** What the value is, in words. */
	public function describe():String {
		return "base";
	}
}

/** A shape, whose area each kind of shape gives. */
abstract class Shape {
	public function new() {}

	/** Its area, in square units. */
	public abstract function area():Int;
}

/** Shared by the package's own modules: described as internal. */
internal class Cache {
	internal static var size = 0;

	public static function clear():Void {
		size = 0;
	}
}

class Special extends Base {
	override public function describe():String {
		return "special";
	}
}

/** A generic item.
	@since 1.0
	@see Reader
**/
@:dox(hide)
class Item<T:sample.Base> implements Reader<T> {
	/** The stored value. */
	public var value(get, never):T;

	private var secret:T;
	public static var count = 0;
	public var limit(get, set):Int;

	function get_limit():Int {
		return count;
	}

	function set_limit(value:Int):Int {
		return count = value;
	}

	/** Creates an item.
		@param value Stored value.
		@param capacity Initial capacity.
		@throws haxe.Exception If capacity is invalid.
	**/
	public function new(value:T, capacity:Int = (0x10)) {
		secret = value;
	}

	function get_value():T {
		return secret;
	}

	/** Reads the stored value.
		@return The stored value.
		@deprecated Use value.
	**/
	@:deprecated("Use value")
	public function read(?count:Int):T {
		return secret;
	}

	public function inferred(scale = 2) {
		return scale + 1;
	}

	public function apply<U:sample.Base>(callback:(U) -> T, item:U):T {
		return callback(item);
	}
}

typedef Record<T> = {
	var value:T;
	@:optional var label:String;
}

typedef Tree = {
	var children:Array<Tree>;
}

enum Choice<T> {
	Empty;
	Legacy(Int);
	/** A choice with data. */
	Some(value:T, ?label:String);
}

/** A unit of count, with per-case constants and members. */
enum Unit {
	/** How many single items it is. */
	public final factor:Int;

	public final symbol:String = "?";

	Single {factor: 1, symbol: "x"};
	Dozen {factor: 12};

	/** The unit everything is counted in. */
	public static function base():Unit
		return Single;

	public function count(units:Int):Int
		return units * factor;

	function hidden():Int
		return 0;
}

abstract Distance(Int) from Int to Int {
	public function new(value:Int) {
		this = value;
	}

	@:from static function parse(value:String):Distance {
		return new Distance(value.length);
	}

	@:to public function label():String {
		return Std.string(this);
	}

	@:op(A + B) static function add(left:Distance, right:Distance):Distance {
		return new Distance((left:Int) + (right:Int));
	}
}

enum abstract Mode(Int) {
	var Active = 1;
	private var Internal = 2;
}

/** A code fixed by a file format. */
enum Format:Int {
	/** Uncompressed. */
	Raw = 1;
	Packed;

	/** Whether it needs decoding. */
	public function compressed():Bool
		return this != Raw;
}

extern class External {}

private class Hidden {}

/** Options for `Service.configure`. */
typedef Options = {
	var name:String;
	@:optional var size:Int;
}

/** Another name for the options, which signatures keep. */
typedef Settings = Options;

typedef Pair<A, B> = {
	var first:A;
	var second:B;
}

typedef Handler = (Int) -> Void;

private class Helper {
	public function new() {}
}

class Service {
	public var settings:Null<Settings>;

	public function new() {}

	/** Signatures name typedefs as written, nested ones included. */
	public function configure(options:Options, ?pair:Pair<Int, Options>, ?handler:Handler):Array<Settings> {
		return [options];
	}

	public function counted() {
		return 3;
	}

	public function total(values:Iterable<Int>):Int {
		var sum = 0;
		for (value in values)
			sum += value;
		return sum;
	}

	/** An internal type in a public signature is referenced, not described. */
	public function detail():sample.internal.Detail {
		return new sample.internal.Detail();
	}

	/** A private type in a public signature stays a named reference. */
	public function helper():Helper {
		return new Helper();
	}
}

/** Greets by name.
	@param times How many times.
**/
function greet(name:String, ?times:Int):String {
	return name;
}

var counter = 0;
final limit:Int = 10;
private var internal = 1;

class Main {
	static function main() {
		new Item(new Base());
		var choice:Choice<Int> = Some(42);
		new Service().configure({name: "x"});
		greet("a");
		counter += limit + internal;
	}
}
