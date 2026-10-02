package haxeon.wasm;

import haxe.io.Bytes;

/** Copies `length` bytes of the shared linear memory at `pointer`; both Wasm backends implement it. */
@:hlNative("haxeon_runtime", "structFromLinear")
extern function bytesFromLinear(pointer:Int, length:Int):Bytes;

/**
 * A failure the host reports while the guest calls it, such as a call to an import it cannot provide. The host
 * throws it with the guest's exception tag (haxeon-host.js), so `catch (e:HostError)` and `catch (e:Dynamic)`
 * handle it like any other exception. Every guest that shares memory with its host includes this module, so it
 * stays small: it does not extend haxe.Exception, whose call stacks would come with it.
 */
class HostError {
	public final message:String;

	public function new(message:String)
		this.message = message;

	public function toString():String
		return message;

	/** Builds the error from `length` bytes of UTF-8 the host wrote at `pointer`; the host then throws it. */
	@:expose public static function fromLinear(pointer:Int, length:Int):Dynamic
		return new HostError(bytesFromLinear(pointer, length).toString());
}
