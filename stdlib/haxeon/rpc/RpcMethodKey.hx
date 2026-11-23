package haxeon.rpc;

/** Request selectors occupy separate namespaces. */
@:wire enum RpcMethodKey {
	@:id(1) Id(id:Int);
	@:id(2) Name(method:String);
	@:id(3) ServiceId(service:String, id:Int);
}
