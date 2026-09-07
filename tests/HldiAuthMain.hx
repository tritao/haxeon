import profiler.HldiClient;

class HldiAuthMain {
	static function rejected(port:Int, token:Null<String>):Bool {
		try {
			var client = new HldiClient("127.0.0.1", port, 3.0, token);
			client.close();
			return false;
		} catch (_:Dynamic) return true;
	}

	static function main():Void {
		var args = Sys.args(), port = args.length == 2 ? Std.parseInt(args[0]) : null;
		if (port == null) throw "Usage: hldi-auth-test.hl PORT TOKEN";
		if (!rejected(port, null)) throw "missing HLDI token was accepted";
		if (!rejected(port, args[1] + "-wrong")) throw "incorrect HLDI token was accepted";
		var client = new HldiClient("127.0.0.1", port, 3.0, args[1]);
		if (client.hello.capabilities & HldiClient.CAP_AUTH_REQUIRED == 0) throw "endpoint did not advertise required authentication";
		client.status();
		client.close();
		Sys.println("PASS: HLDI rejects missing and incorrect credentials");
	}
}
