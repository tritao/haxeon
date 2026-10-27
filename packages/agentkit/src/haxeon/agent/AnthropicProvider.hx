package haxeon.agent;

import haxe.io.Bytes;

/** Anthropic Messages API over a host-supplied streaming transport. */
class AnthropicProvider implements ModelProvider {
	public static inline var DefaultBaseUrl = "https://api.anthropic.com";
	public static inline var ApiVersion = "2023-06-01";

	final transport:HttpTransport;
	final apiKey:String;
	final baseUrl:String;

	public function new(transport:HttpTransport, apiKey:String, baseUrl:String = DefaultBaseUrl) {
		this.transport = transport;
		this.apiKey = apiKey;
		this.baseUrl = baseUrl;
	}

	public function start(request:ModelRequest, sink:ModelSink):Cancelable {
		var stream = new AnthropicStream(sink);
		var headers = [
			new HttpHeaderField("content-type", "application/json"),
			new HttpHeaderField("x-api-key", apiKey),
			new HttpHeaderField("anthropic-version", ApiVersion)
		];
		stream.attach(transport.postStream(new HttpStreamRequest(baseUrl + "/v1/messages", headers, body(request)), stream));
		return stream;
	}

	public static function body(request:ModelRequest):String {
		var fields = [
			JsonWriter.stringField("model", request.model),
			JsonWriter.field("max_tokens", Std.string(request.maxTokens)),
			JsonWriter.field("stream", "true"),
			JsonWriter.field("messages", JsonWriter.array([for (message in request.messages) message.toJson()]))
		];
		if (request.system != "")
			fields.push(JsonWriter.stringField("system", request.system));
		if (request.tools.length > 0)
			fields.push(JsonWriter.field("tools", JsonWriter.array([
				for (tool in request.tools)
					JsonWriter.object([
						JsonWriter.stringField("name", tool.name),
						JsonWriter.stringField("description", tool.description),
						JsonWriter.field("input_schema", tool.schemaJson)
					])
			])));
		return JsonWriter.object(fields);
	}
}

/** Decodes one streamed response. Cancelling silences the sink without reporting an error. */
private class AnthropicStream implements HttpStreamSink implements Cancelable {
	final sink:ModelSink;
	final parser:SseParser;
	var transportRequest:Null<Cancelable>;
	var status = 0;
	var errorBody = "";
	var finished = false;
	var stopReason:Null<StopReason>;
	var toolId = "";
	var toolName = "";
	var toolJson = "";
	var inTool = false;

	public function new(sink:ModelSink) {
		this.sink = sink;
		parser = new SseParser(onEvent);
	}

	public function attach(request:Cancelable):Void {
		transportRequest = request;
		if (finished)
			request.cancel();
	}

	public function cancel():Void {
		if (finished)
			return;
		finished = true;
		if (transportRequest != null)
			transportRequest.cancel();
	}

	public function headers(status:Int):Void
		this.status = status;

	public function chunk(bytes:Bytes):Void {
		if (finished)
			return;
		if (status != 200) {
			if (errorBody.length < 8192)
				errorBody += bytes.toString();
			return;
		}
		parser.feed(bytes);
	}

	public function complete():Void {
		if (finished)
			return;
		if (status != 200) {
			failWith(httpError());
			return;
		}
		parser.finish();
		if (!finished)
			failWith("The model stream ended before the message completed");
	}

	public function fail(message:String):Void
		failWith(message);

	function failWith(message:String):Void {
		if (finished)
			return;
		finished = true;
		sink.fail(message);
	}

	function httpError():String {
		var parsed = JsonObject.parse(errorBody);
		var detail = parsed == null ? null : parsed.object("error");
		var message = detail == null ? "" : detail.string("message");
		return "Model request failed (HTTP " + status + ")" + (message == "" ? "" : ": " + message);
	}

	function onEvent(name:String, data:String):Void {
		if (finished)
			return;
		var event = JsonObject.parse(data);
		if (event == null)
			return;
		switch name {
			case "content_block_start":
				var block = event.object("content_block");
				if (block != null && block.string("type") == "tool_use") {
					inTool = true;
					toolId = block.string("id");
					toolName = block.string("name");
					toolJson = "";
				} else {
					inTool = false;
				}
			case "content_block_delta":
				var delta = event.object("delta");
				if (delta == null)
					return;
				switch delta.string("type") {
					case "text_delta":
						sink.text(delta.string("text"));
					case "input_json_delta":
						toolJson += delta.string("partial_json");
					default:
				}
			case "content_block_stop":
				if (inTool) {
					inTool = false;
					sink.toolUse(new ToolCall(toolId, toolName, toolJson == "" ? "{}" : toolJson));
				}
			case "message_delta":
				var delta = event.object("delta");
				if (delta != null)
					stopReason = reason(delta.string("stop_reason"));
			case "message_stop":
				finished = true;
				sink.complete(stopReason == null ? EndTurn : stopReason);
			case "error":
				var detail = event.object("error");
				failWith("Model error: " + (detail == null ? data : detail.string("message")));
			default:
		}
	}

	static function reason(name:String):StopReason
		return switch name {
			case "tool_use": ToolCalls;
			case "max_tokens": MaxTokens;
			default: EndTurn;
		};
}
