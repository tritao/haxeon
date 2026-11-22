// A function on Int stands for one on Null<Int>, and one returning Null<Int> for one returning Int, as Haxe unifies them: a
// null passed or returned reads as 0, as on Haxe's HashLink target.
function maybe(give:Bool):Null<Int>
	return give ? 9 : null;

function main():Int {
	var seen = 0;
	var record:Null<Int>->Void = (x:Int) -> seen += x + 1;
	record(4);
	record(null);
	var read:Bool->Int = maybe;
	return seen + read(true) + read(false) == 5 + 1 + 9 ? 42 : 1;
}
