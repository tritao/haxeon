enum abstract Alarm(Int) from Int to Int {
	var Warn = 7;
}
abstract Count(Int) to Int {
	public function new(value:Int) this = value;
}
enum Value { Analog(value:Float); }
function read(value:Float):Int return Std.int(value);
function main():Int {
	var alarm:Alarm = Warn;
	var value = Analog(alarm);
	var converted = switch value { case Analog(number): Std.int(number); };
	return converted + read(new Count(35));
}
