package haxeon.rpc;

/** What a peer offers and requires in the handshake, and the limits of each connection it makes. The arrays are copied. */
class RpcPeerOptions {
	/** The application's name, which the peer learns in the handshake. */
	public final application:String;

	/** How long the handshake may take, in milliseconds. */
	public final timeoutMs:Int;

	/** The largest message a connection sends or accepts, in bytes. */
	public final maxMessageBytes:Int;

	/** How many calls a connection may have in flight. */
	public final maxCalls:Int;

	/** How many bytes a connection may queue to send. */
	public final maxQueuedBytes:Int;

	final capabilities:Array<String>;
	final required:Array<String>;

	/**
	 * Options for `application`, offering `capabilities` and requiring the peer to offer each of `required` (which must
	 * be among them). Throws for invalid limits or names.
	 */
	public function new(application:String, capabilities:Array<String>, ?required:Array<String>, timeoutMs:Int = 5000,
			maxMessageBytes:Int = 4 * 1024 * 1024,
			maxCalls:Int = 256, maxQueuedBytes:Int = 8 * 1024 * 1024) {
		RpcProtocol.validate(Hello(RpcProtocol.VERSION, RpcProtocol.CODEC_VERSION, application, capabilities));
		var requirements = required == null ? [] : required.copy();
		RpcProtocol.validate(Hello(RpcProtocol.VERSION, RpcProtocol.CODEC_VERSION, application, requirements));
		for (capability in requirements)
			if (capabilities.indexOf(capability) < 0)
				throw new haxe.Exception("Required capability must be offered");
		if (timeoutMs <= 0
			|| maxMessageBytes < 128
			|| maxCalls < 1
			|| maxQueuedBytes < maxMessageBytes
			|| maxQueuedBytes > 0x7fffffff - maxMessageBytes)
			throw new haxe.Exception("Invalid RPC peer limits");
		RpcProtocol.encode(Hello(RpcProtocol.VERSION, RpcProtocol.CODEC_VERSION, application, capabilities),
			maxMessageBytes);
		this.application = application;
		this.capabilities = capabilities.copy();
		this.required = requirements;
		this.timeoutMs = timeoutMs;
		this.maxMessageBytes = maxMessageBytes;
		this.maxCalls = maxCalls;
		this.maxQueuedBytes = maxQueuedBytes;
	}

	/** The capabilities offered, in a new array. */
	public function offered():Array<String>
		return capabilities.copy();

	/** The capabilities required of the peer, in a new array. */
	public function requirements():Array<String>
		return required.copy();
}
