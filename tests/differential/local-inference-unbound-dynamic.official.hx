// A local nothing fixes the type of is Dynamic, as in Haxe: an empty array never pushed to, a `var x;` never assigned,
// a `var x = null` never assigned again, an array copied from one, and an empty array pushed into another.
class Main {
	static function main():Void {
		var values = [];
		Sys.println(values.length + " " + values);

		var unused;
		var nothing = null;
		Sys.println(nothing == null);

		var copies = [];
		var copy = copies.copy();
		Sys.println(copy.length);

		var rows = [];
		var row = [];
		rows.push(row);
		Sys.println(rows.length + " " + rows[0].length);
	}
}
