package sys.net;

#if !wasm
@:hlNative("haxeon_runtime", "__host_resolve")
extern function hostResolve(name:String):Int;

@:hlNative("haxeon_runtime", "__host_to_string")
extern function hostToString(ip:Int):String;

@:hlNative("haxeon_runtime", "__host_reverse")
extern function hostReverse(ip:Int):Null<String>;

@:hlNative("haxeon_runtime", "__host_local")
extern function hostLocal():Null<String>;
#end

/** An IPv4 host, as in Haxe: its name and the address it resolves to. */
class Host {
	public var host(default, null):String;

	/** The IPv4 address, in network byte order. */
	public var ip(default, null):Int;

	/** Resolves `name`, a host name or a dotted address; throws when it does not resolve. */
	public function new(name:String) {
		#if wasm
		throw "Hosts are not available on Wasm";
		#else
		host = name;
		ip = hostResolve(name);
		if (ip == -1)
			throw 'Unresolved host $name';
		#end
	}

	/** The host for an address a socket reports, named by the address. */
	@:allow(sys.net.Socket)
	static function ofIp(ip:Int):Host {
		var result = new Host("127.0.0.1");
		result.ip = ip;
		result.host = result.toString();
		return result;
	}

	/** The address in dotted form. */
	public function toString():String {
		#if wasm
		return host;
		#else
		return hostToString(ip);
		#end
	}

	/** The name the address resolves back to. */
	public function reverse():String {
		#if wasm
		throw "Hosts are not available on Wasm";
		#else
		var name = hostReverse(ip);
		if (name == null)
			throw 'No name for ${toString()}';
		return name;
		#end
	}

	/** The name of the machine running the program. */
	public static function localhost():String {
		#if wasm
		throw "Hosts are not available on Wasm";
		#else
		var name = hostLocal();
		if (name == null)
			throw "No local host name";
		return name;
		#end
	}
}
