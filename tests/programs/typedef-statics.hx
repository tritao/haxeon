// A type's statics are reached through a typedef of it, as in Haxe: a call, a function value and a field.
class Real {
	public static final BASE = 40;

	public static function make():Int
		return BASE + 2;
}

typedef Alias = Real;

function main():Int {
	var made = Alias.make;
	return Alias.make() == 42 && made() == 42 && Alias.BASE == 40 ? 42 : 1;
}
