import haxe.ds.ObjectMap;

enum DeferredNominalMapValue {
	Empty;
	Link(next:DeferredNominalMapValue);
}

class NominalEnumMapKey {
	public function new() {}
}
struct NominalLayoutAnchor {
	public final value:Int;
	public function new(value:Int) this.value = value;
}

class ErasedNominalEnumMapCase {
	// Register another physical owner without constructing it on the entry path.
	public static function unused():Bool
		return new ObjectMap<NominalEnumMapKey, DeferredNominalMapValue>().exists(new NominalEnumMapKey());

	public static function run():Int {
		var key = new NominalEnumMapKey();
		var numbers = new ObjectMap<NominalEnumMapKey, Int>();
		var values = new ObjectMap<NominalEnumMapKey, NominalLayoutAnchor>();
		var erased:ObjectMap<Dynamic, Dynamic> = numbers;
		erased.set(key, 42);
		return !values.exists(key) && numbers.get(key) == 42 ? 42 : 1;
	}
}
function main():Int return ErasedNominalEnumMapCase.run();
