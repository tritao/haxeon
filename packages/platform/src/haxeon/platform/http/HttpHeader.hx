package haxeon.platform.http;

/** One copied HTTP response header. Duplicate headers remain separate entries. */
class HttpHeader {
	/** The header's name. */
	public final name:String;

	/** Its value. */
	public final value:String;

	/** A header `name: value`. */
	public function new(name:String, value:String) {
		this.name = name;
		this.value = value;
	}
}
