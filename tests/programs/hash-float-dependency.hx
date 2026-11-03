import haxeon.Hashing;
struct Key implements Hashable { public final value:Float; public function new(value:Float) this.value=value; }
function main():Int return Hashing.hash(new Key(Math.POSITIVE_INFINITY)) == Hashing.hash(new Key(Math.POSITIVE_INFINITY)) ? 42 : 1;
