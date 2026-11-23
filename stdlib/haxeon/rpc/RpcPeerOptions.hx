package haxeon.rpc;

/** Immutable handshake policy and per-generation limits. Arrays are copied. */
class RpcPeerOptions {
	public final application:String;
	public final timeoutMs:Int;
	public final maxMessageBytes:Int;
	public final maxCalls:Int;
	public final maxQueuedBytes:Int;

	final capabilities:Array<String>;
	final required:Array<String>;

	public function new(application:String, capabilities:Array<String>, ?required:Array<String>, timeoutMs:Int = 5000,
			maxMessageBytes:Int = 4 * 1024 * 1024,
			maxCalls:Int = 256, maxQueuedBytes:Int = 8 * 1024 * 1024) {
		RpcProtocol.validate(Hello(RpcProtocol.VERSION, RpcProtocol.CODEC_VERSION, application, capabilities));
		var requirements = required == null ? [] : required.copy();
		RpcProtocol.validate(Hello(RpcProtocol.VERSION, RpcProtocol.CODEC_VERSION, application, requirements));
		for (capability in requirements)
			if (capabilities.indexOf(capability) < 0)
				throw "Required capability must be offered";
		if (timeoutMs <= 0
			|| maxMessageBytes < 128
			|| maxCalls < 1
			|| maxQueuedBytes < maxMessageBytes
			|| maxQueuedBytes > 0x7fffffff - maxMessageBytes)
			throw "Invalid RPC peer limits";
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

	public function offered():Array<String>
		return capabilities.copy();

	public function requirements():Array<String>
		return required.copy();
}
