package haxe.wire;

/** Error raised when a MessagePack value is malformed or exceeds a limit. */
class MessagePackError extends haxe.Exception {
	public function new(message:String)
		super(message);
}
