package haxeon.platform.http;

/** One copied HTTP response header. Duplicate headers remain separate entries. */
class HttpHeader {
	public final name:String;
	public final value:String;

	public function new(name:String, value:String) {
		this.name = name;
		this.value = value;
	}
}
