import haxe.ds.ObjectMap;

enum DeferredTagMapValue {
	Rapid;
	Cut;
}

class TagEnumMapKey {
	public function new() {}
}
struct TagLayoutAnchor {
	public final value:Int;
	public function new(value:Int) this.value = value;
}

class ErasedTagEnumMapCase {
	// Register another physical owner without constructing it on the entry path.
	public static function unused():Bool
		return new ObjectMap<TagEnumMapKey, DeferredTagMapValue>().exists(new TagEnumMapKey());

	public static function run():Int {
		var key = new TagEnumMapKey();
		var numbers = new ObjectMap<TagEnumMapKey, Int>();
		var values = new ObjectMap<TagEnumMapKey, TagLayoutAnchor>();
		var erased:ObjectMap<Dynamic, Dynamic> = numbers;
		erased.set(key, 42);
		return !values.exists(key) && numbers.get(key) == 42 ? 42 : 1;
	}
}
function main():Int return ErasedTagEnumMapCase.run();
