package haxeon.platform;

/** Structured package failure. Codes are scoped to domain. */
class PlatformError extends haxe.Exception {
	/** The library the code comes from, such as `nativekit`. */
	public final domain:String;

	/** The library's error code. */
	public final code:Int;

	/** The call that failed. */
	public final operation:String;

	/** The library's own explanation, or null. */
	public final diagnostic:Null<String>;

	/** An error with `code` from `domain` in `operation`. */
	public function new(domain:String, code:Int, operation:String, diagnostic:Null<String>) {
		super('$operation failed ($code) [$domain]${diagnostic == null || diagnostic.length == 0 ? "" : ": " + diagnostic}');
		this.domain = domain;
		this.code = code;
		this.operation = operation;
		this.diagnostic = diagnostic;
	}
}
