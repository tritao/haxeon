/** A read-only generic view keeps each map's concrete storage behind typed callbacks. */
class ReadView<V> {
	final read:String->Null<V>;
	final has:String->Bool;

	public function new(read:String->Null<V>, has:String->Bool) {
		this.read = read;
		this.has = has;
	}

	public function get(key:String):Null<V> return read(key);
	public function exists(key:String):Bool return has(key);
}

function main():Int {
	var flags:Map<String, Bool> = [];
	flags.set("false", false);
	flags.set("true", true);
	var values = new ReadView<Bool>((key:String) -> flags.get(key), (key:String) -> flags.exists(key));
	if (!values.exists("false") || !values.exists("true") || values.exists("missing")) return 1;
	if (values.get("false") != false || values.get("true") != true || values.get("missing") != null) return 2;
	var strings:Map<String, String> = [];
	strings.set("text", "ok");
	var references = new ReadView<String>((key:String) -> strings.get(key), (key:String) -> strings.exists(key));
	if (!references.exists("text") || references.exists("missing")) return 3;
	if (references.get("text") != "ok" || references.get("missing") != null) return 4;
	return 42;
}
