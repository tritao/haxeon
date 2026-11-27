package haxeon.rpc;

/** How a request names its method: each kind of name is its own namespace. */
@:wire enum RpcMethodKey {
	/** The method numbered `id`. */
	@:id(1) Id(id:Int);

	/** The method of the qualified name `method`. */
	@:id(2) Name(method:String);

	/** The method numbered `id` of the service `service`. */
	@:id(3) ServiceId(service:String, id:Int);
}
