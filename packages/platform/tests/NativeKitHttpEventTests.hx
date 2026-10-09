import haxe.io.Bytes;
import haxeon.platform.NativeKitEvents;
import nativekit.ffi.NativeKitNet;
import nativekit.ffi.NativeKitNetTypes.HttpClientOptions;
import nativekit.ffi.NativeKitNetTypes.HttpHeader;
import nativekit.ffi.NativeKitNetTypes.HttpMethod;
import nativekit.ffi.NativeKitNetTypes.HttpRequestMode;
import nativekit.ffi.NativeKitNetTypes.HttpRequestOptions;
import nativekit.ffi.NativeKitTypes.Result;

/** Loopback contract test for copied NativeKit HTTP events and byte-span headers. */
class NativeKitHttpEventTests {
	public static function run(events:NativeKitEvents):Bool {
		var fixturePort = Std.parseInt(Sys.getEnv("NATIVEKIT_HTTP_FIXTURE_PORT"));
		if (fixturePort == null || fixturePort <= 0)
			return true; // The test runner omits the optional loopback fixture when Node is unavailable.

		var subscription:Null<haxeon.platform.NativeKitEvents.NativeKitEventSubscription> = null;
		var result = false;
		var requestId:haxe.Int64 = haxe.Int64.ofInt(0);
		try {
			var clientOptions = new HttpClientOptions();
			clientOptions.set_flags(1); // NK_HTTP_CLIENT_ALLOW_HTTP, restricted to the local fixture.
			var clientResult = NativeKitNet.nk_http_client_create(clientOptions);
			if (clientResult.status == Result.ErrorUnsupported)
				return true;
			if (clientResult.status != Result.Ok)
				throw 'HTTP client creation failed: ${clientResult.status}';
			var clientOwner = clientResult.out_client;
			var client = clientOwner.borrow();

			var sawHeaders = false, sawComplete = false, copiedValuesOk = false;
			var observed:Array<String> = [];
			subscription = events.listen(function(value) switch value {
				case HttpHeaders(_, id, status, response):
					observed.push('headers id=$id result=$status code=${response.statusCode}');
					if (Std.string(id) == Std.string(requestId))
						sawHeaders = status == Result.Ok && response.statusCode == 201 && response.body.length == 0;
				case HttpComplete(_, id, status, response):
					observed.push('complete id=$id result=$status code=${response.statusCode}');
					if (Std.string(id) != Std.string(requestId)) return;
					var token = "", state = "";
					for (header in response.headers) {
						if (header.name.toLowerCase() == "x-relay-token") token = header.value;
						if (header.name.toLowerCase() == "x-relay-state") state = header.value;
					}
					observed.push('copied headers=$token/$state body="${response.body.toString()}"');
					copiedValuesOk = status == Result.Ok && response.statusCode == 201 && token == "alpha" && state == "beta"
						&& response.body.toString() == "ticket-ok";
					sawComplete = true;
				case _:
			});

			var headers = new HttpHeader();
			headers.set_name_bytes(Bytes.ofString("Content-Type"));
			headers.set_value_bytes(Bytes.ofString("application/json"));
			var requestOptions = new HttpRequestOptions();
			requestOptions.set_method(HttpMethod.Post);
			requestOptions.set_url('http://127.0.0.1:$fixturePort/relay/ticket');
			requestOptions.set_headers([headers]);
			requestOptions.set_body_bytes(Bytes.ofString('{"ticket":true}'));
			requestOptions.set_mode(HttpRequestMode.Buffered);
			requestOptions.set_timeout_ms(3000);
			requestOptions.set_max_response_size(4096);
			var requestResult = NativeKitNet.nk_http_request(client, requestOptions);
			if (requestResult.status != Result.Ok)
				throw 'HTTP request start failed: ${requestResult.status}';
			requestId = requestResult.out_request;

			for (_ in 0...400) {
				events.wait(0.01);
				while (events.poll()) {}
				if (sawComplete) break;
			}
			result = sawHeaders && sawComplete && copiedValuesOk;
			if (!result)
				trace('NativeKit HTTP event smoke incomplete for request $requestId: ' + observed.join("; "));
			var closeResult = clientOwner.close();
			result = result && closeResult == Result.Ok;
		} catch (error:Dynamic) {
			trace("NativeKit HTTP event smoke failed: " + Std.string(error));
			result = false;
		}
		if (subscription != null) subscription.dispose();
		return result;
	}
}
