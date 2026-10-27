package haxeon.platform;

/** Structured binding or backend failure. Codes are scoped to domain. */
class PlatformError extends haxe.Exception {
	public final domain:String;
	public final code:Int;
	public final operation:String;
	public final diagnostic:Null<String>;

	public function new(domain:String, code:Int, operation:String, diagnostic:Null<String>) {
		super('$operation failed ($code) [$domain]${diagnostic == null || diagnostic.length == 0 ? "" : ": " + diagnostic}');
		this.domain = domain;
		this.code = code;
		this.operation = operation;
		this.diagnostic = diagnostic;
	}
}
