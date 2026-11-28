import haxe.io.Bytes;
import haxeon.platform.event.EventPump;
import haxeon.platform.http.HttpClient;
import haxeon.platform.http.HttpExchange;
import haxeon.platform.http.HttpRequest;
import nativekit.ffi.NativeKitNetTypes.HttpMethod;

/**
 * Loopback contract test for HttpClient: a buffered request's response and its copied headers, and a streaming one's
 * body through onData, each answered through the event pump.
 */
class NativeKitHttpEventTests {
	public static function run(events:EventPump):Bool {
		var fixturePort = Std.parseInt(Sys.getEnv("NATIVEKIT_HTTP_FIXTURE_PORT"));
		if (fixturePort == null || fixturePort <= 0)
			return true; // The test runner omits the optional loopback fixture when Node is unavailable.
		var client = switch HttpClient.create(events, true) {
			case Ok(created): created;
			case Err(Unsupported(_)): return true;
			case Err(error):
				trace("HTTP client creation failed: " + error.describe());
				return false;
		};
		var result = false;
		try {
			var request = new HttpRequest(HttpMethod.Post, 'http://127.0.0.1:$fixturePort/relay/ticket')
				.header("Content-Type", "application/json");
			request.body = Bytes.ofString('{"ticket":true}');
			request.timeoutSeconds = 3;
			request.maxResponseBytes = 4096;
			var buffered = client.send(request);
			var headersOk = false, completeOk = false;
			buffered.response.onComplete(function(outcome) switch outcome {
				case Success(Ok(response)): headersOk = response.statusCode == 201 && response.body.length == 0;
				case _:
			});
			buffered.complete.onComplete(function(outcome) switch outcome {
				case Success(Ok(response)):
					var token = "", state = "";
					for (header in response.headers) {
						if (header.name.toLowerCase() == "x-relay-token") token = header.value;
						if (header.name.toLowerCase() == "x-relay-state") state = header.value;
					}
					completeOk = response.statusCode == 201 && token == "alpha" && state == "beta"
						&& response.body.toString() == "ticket-ok";
				case other:
					trace("buffered HTTP request ended " + Std.string(other));
			});
			await(events, buffered);

			request.streaming = true;
			var streamed = client.send(request);
			var body = new StringBuf();
			streamed.onData(function(piece) body.add(piece.toString()));
			var streamOk = false;
			streamed.complete.onComplete(function(outcome) switch outcome {
				case Success(Ok(response)): streamOk = response.statusCode == 201 && body.toString() == "ticket-ok";
				case other:
					trace("streaming HTTP request ended " + Std.string(other));
			});
			await(events, streamed);
			result = headersOk && completeOk && streamOk;
			if (!result)
				trace('HttpClient smoke incomplete: headers $headersOk, complete $completeOk, stream $streamOk '
					+ 'body "${body.toString()}"');
		} catch (error:Dynamic) {
			trace("HttpClient smoke failed: " + Std.string(error));
			result = false;
		}
		client.dispose();
		return result;
	}

	static function await(events:EventPump, exchange:HttpExchange):Void
		for (_ in 0...400) {
			events.wait(0.01);
			while (events.poll()) {}
			if (exchange.isComplete())
				return;
		}
}
