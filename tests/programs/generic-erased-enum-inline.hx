import haxe.ds.ObjectMap;

enum DeferredInlineMapValue {
	Empty;
	Number(value:Int);
}

class InlineEnumMapKey {
	public function new() {}
}
struct InlineLayoutAnchor {
	public final value:Int;
	public function new(value:Int) this.value = value;
}

class ErasedInlineEnumMapCase {
	// Register another physical owner without constructing it on the entry path.
	public static function unused():Bool
		return new ObjectMap<InlineEnumMapKey, DeferredInlineMapValue>().exists(new InlineEnumMapKey());

	public static function run():Int {
		var key = new InlineEnumMapKey();
		var numbers = new ObjectMap<InlineEnumMapKey, Int>();
		var values = new ObjectMap<InlineEnumMapKey, InlineLayoutAnchor>();
		var erased:ObjectMap<Dynamic, Dynamic> = numbers;
		erased.set(key, 42);
		return !values.exists(key) && numbers.get(key) == 42 ? 42 : 1;
	}
}
function main():Int return ErasedInlineEnumMapCase.run();
