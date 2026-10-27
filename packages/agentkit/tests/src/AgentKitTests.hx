import haxe.io.Bytes;
import haxeon.agent.*;

private class EchoTool extends AgentTool {
	public var runs = 0;

	public function new(access:ToolAccess = ReadOnly)
		super("echo", "Echo the text back", new ToolSchema().string("text", "Text to echo"), access);

	override function summarize(input:JsonObject):String
		return "echo " + input.string("text");

	override function execute(input:JsonObject, context:ToolContext, done:ToolResult->Void):Void {
		runs++;
		done(ToolResult.ok("echo:" + input.string("text")));
	}
}

/** Completes only when the test calls `finish`, to model host work that outlives a frame. */
private class SlowTool extends AgentTool {
	public var finish:ToolResult->Void = function(_) {};

	public function new()
		super("slow", "Waits", new ToolSchema(), ReadOnly);

	override function execute(input:JsonObject, context:ToolContext, done:ToolResult->Void):Void
		finish = done;
}

private class ThrowingTool extends AgentTool {
	public function new()
		super("boom", "Always throws", new ToolSchema(), ReadOnly);

	override function execute(input:JsonObject, context:ToolContext, done:ToolResult->Void):Void
		throw "exploded";
}

private class AskAll implements ToolPolicy {
	public function new() {}

	public function decide(tool:AgentTool, input:JsonObject):PolicyDecision
		return Ask;
}

private class DenyAll implements ToolPolicy {
	public function new() {}

	public function decide(tool:AgentTool, input:JsonObject):PolicyDecision
		return Deny("no tools today");
}

private class FakeTransport implements HttpTransport {
	public var request:HttpStreamRequest = new HttpStreamRequest("", [], "");
	public var sink:HttpStreamSink = new IgnoreSink();
	public var cancelled = false;

	public function new() {}

	public function postStream(request:HttpStreamRequest, sink:HttpStreamSink):Cancelable {
		this.request = request;
		this.sink = sink;
		var owner = this;
		return new FakeCancel(function() owner.cancelled = true);
	}
}

private class IgnoreSink implements HttpStreamSink {
	public function new() {}

	public function headers(status:Int):Void {}

	public function chunk(bytes:Bytes):Void {}

	public function complete():Void {}

	public function fail(message:String):Void {}
}

private class FakeCancel implements Cancelable {
	final action:Void->Void;

	public function new(action:Void->Void)
		this.action = action;

	public function cancel():Void
		action();
}

private class Recorder implements ModelSink {
	public var received = "";
	public final calls:Array<ToolCall> = [];
	public var reason:Null<StopReason>;
	public var failure:Null<String>;

	public function new() {}

	public function text(delta:String):Void
		received += delta;

	public function toolUse(call:ToolCall):Void
		calls.push(call);

	public function complete(reason:StopReason):Void
		this.reason = reason;

	public function fail(message:String):Void
		failure = message;
}

class AgentKitTests {
	static var checks = 0;

	static function check(ok:Bool, label:String):Void {
		checks++;
		if (!ok)
			throw "FAILED: " + label;
	}

	static function call(id:String, name:String, json:String):ToolCall
		return new ToolCall(id, name, json);

	static function agent(provider:ModelProvider, tools:Array<AgentTool>, policy:ToolPolicy):Agent
		return new Agent(new AgentOptions(provider, "test-model", "system prompt", tools, policy));

	static function names(events:Array<AgentEvent>):String {
		var parts:Array<String> = [];
		for (event in events)
			parts.push(switch event {
				case RunStarted: "start";
				case TurnStarted(turn): "turn" + turn;
				case TextDelta(text): "text:" + text;
				case MessageCompleted(_): "message";
				case ToolStarted(call): "tool:" + call.name;
				case ApprovalRequested(call, _): "ask:" + call.id;
				case ToolCompleted(call, result): "done:" + call.id + (result.isError ? "!" : "");
				case RunEnded(reason): "end:" + switch reason {
						case EndTurn: "end_turn";
						case ToolCalls: "tools";
						case MaxTokens: "max_tokens";
						case Aborted: "aborted";
						case Failed(message): "failed(" + message + ")";
					};
			});
		return parts.join(" ");
	}

	static function record(agent:Agent):Array<AgentEvent> {
		var events:Array<AgentEvent> = [];
		agent.onEvent = function(event) events.push(event);
		return events;
	}

	static function sse():Void {
		var seen:Array<String> = [];
		var parser = new SseParser(function(name, data) seen.push(name + "|" + data));
		var payload = Bytes.ofString(": comment\r\nevent: greet\r\ndata: héllo\r\ndata: world\r\n\r\ndata: bare\n\nevent: tail\ndata: unterminated");
		// One byte at a time exercises splits inside lines, CRLF pairs and UTF-8 sequences.
		for (index in 0...payload.length)
			parser.feed(payload.sub(index, 1));
		check(seen.length == 2, "two complete events before finish");
		parser.finish();
		check(seen.join(";") == "greet|héllo\nworld;message|bare;tail|unterminated", "SSE events: " + seen.join(";"));
	}

	static function schemaAndMessages():Void {
		var schema = new ToolSchema().string("path", "File path").integer("limit", "Max lines").string("mode", "Mode", false, ["a", "b"]).toJson();
		var parsed = JsonObject.parse(schema);
		check(parsed != null && parsed.string("type") == "object", "schema is an object");
		var properties = parsed.object("properties");
		check(properties.object("limit").string("type") == "integer", "integer property");
		check(properties.object("mode").strings("enum").join(",") == "a,b", "enum choices");
		check(parsed.strings("required").join(",") == "path", "only path is required: " + parsed.strings("required").join(","));

		var message = new Message(Assistant, [Text("hi \"there\"\n"), ToolUse("t1", "echo", "{\"text\":\"x\"}"), ToolOutput("t1", "r", true)]);
		var restored = Message.fromJson(JsonObject.parse(message.toJson()));
		check(restored != null && restored.toJson() == message.toJson(), "message round trip");
		check(restored.text() == "hi \"there\"\n", "text escapes survive");
		check(restored.toolUses().length == 1 && restored.toolUses()[0].name == "echo", "tool uses extracted");
		check(JsonObject.parse("[1]") == null && JsonObject.parse("nope") == null && JsonObject.parse("3") == null, "non-objects rejected");
	}

	static function plainReply():Void {
		var provider = new ScriptedProvider([ScriptedResponse.say("hello")]);
		var a = agent(provider, [], new SupervisedPolicy());
		var events = record(a);
		check(a.send("hi"), "send accepted");
		check(names(events) == "start turn1 text:hello message end:end_turn", names(events));
		check(a.state == Idle, "idle after run");
		check(a.messages().length == 2 && a.messages()[1].text() == "hello", "history holds both messages");
		check(provider.requests[0].system == "system prompt" && provider.requests[0].model == "test-model", "request carries system and model");
	}

	static function toolRoundTrip():Void {
		var echo = new EchoTool();
		var provider = new ScriptedProvider([
			ScriptedResponse.useTools("looking", [call("c1", "echo", "{\"text\":\"a\"}"), call("c2", "echo", "{\"text\":\"b\"}")]),
			ScriptedResponse.say("done")
		]);
		var a = agent(provider, [echo], new SupervisedPolicy());
		var events = record(a);
		a.send("go");
		check(names(events) == "start turn1 text:looking message tool:echo done:c1 tool:echo done:c2 turn2 text:done message end:end_turn", names(events));
		check(echo.runs == 2, "both calls ran sequentially");
		var second = provider.requests[1].messages;
		check(second.length == 3, "request two carries user, assistant, tool results");
		switch second[2].content[1] {
			case ToolOutput(id, content, isError):
				check(id == "c2" && content == "echo:b" && !isError, "second result recorded");
			default:
				check(false, "tool result block expected");
		}
		check(provider.requests[0].tools[0].name == "echo", "tools offered to the model");
	}

	static function badCalls():Void {
		var provider = new ScriptedProvider([
			ScriptedResponse.useTools("", [call("u", "missing", "{}"), call("j", "echo", "[oops"), call("t", "boom", "{}")]),
			ScriptedResponse.say("recovered")
		]);
		var a = agent(provider, [new EchoTool(), new ThrowingTool()], new SupervisedPolicy());
		var events = record(a);
		a.send("go");
		check(names(events).indexOf("done:u! ") >= 0 && names(events).indexOf("done:j! ") >= 0 && names(events).indexOf("done:t! ") >= 0, names(events));
		check(names(events).indexOf("end:end_turn") > 0, "run continues after bad calls: " + names(events));
	}

	static function policies():Void {
		var echo = new EchoTool(Mutating);
		var a = agent(new ScriptedProvider([ScriptedResponse.useTools("", [call("c", "echo", "{\"text\":\"x\"}")]), ScriptedResponse.say("ok")]), [echo],
			new DenyAll());
		var events = record(a);
		a.send("go");
		check(echo.runs == 0 && names(events).indexOf("done:c!") > 0, "denied call never executes: " + names(events));

		var supervised = new EchoTool(Mutating);
		var s = agent(new ScriptedProvider([ScriptedResponse.useTools("", [call("c", "echo", "{\"text\":\"x\"}")]), ScriptedResponse.say("ok")]), [supervised],
			new SupervisedPolicy());
		var sEvents = record(s);
		s.send("go");
		check(s.state == AwaitingApproval && supervised.runs == 0, "mutating call waits for approval");
		check(names(sEvents).indexOf("ask:c") > 0, "approval requested");
		s.resolveApproval("stale", true);
		check(s.state == AwaitingApproval, "stale approval ignored");
		check(!s.send("again"), "send rejected while awaiting approval");
		s.resolveApproval("c", true);
		check(supervised.runs == 1 && s.state == Idle, "approved call ran and run finished");

		var declined = new EchoTool(Mutating);
		var d = agent(new ScriptedProvider([ScriptedResponse.useTools("", [call("c", "echo", "{\"text\":\"x\"}")]), ScriptedResponse.say("ok")]), [declined],
			new AskAll());
		var dEvents = record(d);
		d.send("go");
		d.resolveApproval("c", false);
		check(declined.runs == 0 && names(dEvents).indexOf("done:c!") > 0 && d.state == Idle, "declined call reported as error: " + names(dEvents));
	}

	static function abortKeepsHistoryValid():Void {
		var slow = new SlowTool();
		var provider = new ScriptedProvider([
			ScriptedResponse.useTools("", [call("a", "slow", "{}"), call("b", "slow", "{}")]),
			ScriptedResponse.say("never")
		]);
		var a = agent(provider, [slow], new SupervisedPolicy());
		var events = record(a);
		a.send("go");
		check(a.state == RunningTool, "waiting on tool");
		a.abort();
		check(a.state == Idle && names(events).indexOf("end:aborted") > 0, "aborted: " + names(events));
		slow.finish(ToolResult.ok("late"));
		check(provider.requests.length == 1, "late tool completion does not continue the run");
		var history = a.messages();
		check(history.length == 3 && history[2].content.length == 2, "every tool call has a result after abort");
		check(a.send("again"), "agent usable after abort");
	}

	static function modelSwitch():Void {
		var provider = new ScriptedProvider([ScriptedResponse.say("a"), ScriptedResponse.say("b")]);
		var a = agent(provider, [], new SupervisedPolicy());
		a.send("one");
		a.model = "other-model";
		a.send("two");
		check(provider.requests[0].model == "test-model" && provider.requests[1].model == "other-model", "model changes apply to the next run");
	}

	static function failuresAndLimits():Void {
		var a = agent(new ScriptedProvider([ScriptedResponse.failWith("network down")]), [], new SupervisedPolicy());
		var events = record(a);
		a.send("hi");
		check(names(events).indexOf("end:failed(network down)") > 0 && a.state == Idle, names(events));

		var loop = [for (i in 0...5) ScriptedResponse.useTools("", [call("c" + i, "echo", "{\"text\":\"x\"}")])];
		var limited = new Agent(new AgentOptions(new ScriptedProvider(loop), "m", "", [new EchoTool()], new SupervisedPolicy(), 100, 3));
		var limitedEvents = record(limited);
		limited.send("loop");
		check(names(limitedEvents).indexOf("end:failed(Stopped after 3 model turns)") > 0, names(limitedEvents));
	}

	static function sessions():Void {
		var a = agent(new ScriptedProvider([ScriptedResponse.useTools("t", [call("c", "echo", "{\"text\":\"x\"}")]), ScriptedResponse.say("fin")]),
			[new EchoTool()], new SupervisedPolicy());
		a.send("go");
		var snapshot = a.snapshot();
		var b = agent(new ScriptedProvider([]), [], new SupervisedPolicy());
		check(b.restore(snapshot), "restore accepted");
		check(b.snapshot() == snapshot, "snapshot round trip is stable");
		check(!b.restore("{\"version\":2,\"messages\":[]}") && !b.restore("garbage"), "bad snapshots rejected");
		check(b.snapshot() == snapshot, "failed restore leaves history alone");
	}

	static function anthropicBody():Void {
		var tool = new EchoTool();
		var request = new ModelRequest("claude-x", "be brief", [Message.user("hi")], [new ToolSpec(tool.name, tool.description, tool.schema.toJson())], 512);
		var body = JsonObject.parse(AnthropicProvider.body(request));
		check(body.string("model") == "claude-x" && body.int("max_tokens") == 512 && body.bool("stream"), "body basics");
		check(body.string("system") == "be brief", "system prompt");
		check(body.objects("messages")[0].string("role") == "user", "messages present");
		var tools = body.objects("tools");
		check(tools.length == 1 && tools[0].object("input_schema").string("type") == "object", "tool schema embedded as an object");
	}

	static function reasonName(reason:Null<StopReason>):String
		return reason == null ? "none" : switch reason {
			case EndTurn: "end_turn";
			case ToolCalls: "tools";
			case MaxTokens: "max_tokens";
			case Aborted: "aborted";
			case Failed(message): "failed";
		};

	static function bytes(text:String):Bytes
		return Bytes.ofString(text);

	static function event(name:String, data:String):String
		return "event: " + name + "\ndata: " + data + "\n\n";

	static function anthropicStream():Void {
		var transport = new FakeTransport();
		var provider = new AnthropicProvider(transport, "sk-test", "https://example.test");
		var recorder = new Recorder();
		var request = new ModelRequest("m", "", [Message.user("hi")], [], 64);
		provider.start(request, recorder);
		check(transport.request.url == "https://example.test/v1/messages", "endpoint");
		var headers = [for (header in transport.request.headers) header.name + "=" + header.value];
		check(headers.indexOf("x-api-key=sk-test") >= 0 && headers.indexOf("anthropic-version=2023-06-01") >= 0, "auth headers");

		var stream = event("message_start", "{\"type\":\"message_start\"}")
			+ event("content_block_start", "{\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}")
			+ event("content_block_delta", "{\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Hel\"}}")
			+ event("content_block_delta", "{\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"lo é\"}}")
			+ event("content_block_stop", "{\"index\":0}")
			+ event("content_block_start", "{\"index\":1,\"content_block\":{\"type\":\"tool_use\",\"id\":\"toolu_1\",\"name\":\"echo\",\"input\":{}}}")
			+ event("content_block_delta", "{\"index\":1,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"te\"}}")
			+ event("content_block_delta", "{\"index\":1,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"xt\\\":\\\"hi\\\"}\"}}")
			+ event("content_block_stop", "{\"index\":1}")
			+ event("message_delta", "{\"delta\":{\"stop_reason\":\"tool_use\"}}")
			+ event("message_stop", "{}");
		transport.sink.headers(200);
		var all = bytes(stream);
		var offset = 0;
		while (offset < all.length) {
			var size = Std.int(Math.min(7, all.length - offset));
			transport.sink.chunk(all.sub(offset, size));
			offset += size;
		}
		transport.sink.complete();
		check(recorder.received == "Hello é", "streamed text: " + recorder.received);
		check(recorder.calls.length == 1 && recorder.calls[0].id == "toolu_1" && recorder.calls[0].inputJson == "{\"text\":\"hi\"}", "assembled tool input");
		check(reasonName(recorder.reason) == "tools" && recorder.failure == null, "stop reason");

		var failing = new FakeTransport();
		var failedRecorder = new Recorder();
		new AnthropicProvider(failing, "bad").start(request, failedRecorder);
		failing.sink.headers(401);
		failing.sink.chunk(bytes("{\"type\":\"error\",\"error\":{\"message\":\"invalid x-api-key\"}}"));
		failing.sink.complete();
		check(failedRecorder.failure == "Model request failed (HTTP 401): invalid x-api-key", "http error: " + failedRecorder.failure);

		var truncated = new FakeTransport();
		var truncatedRecorder = new Recorder();
		new AnthropicProvider(truncated, "k").start(request, truncatedRecorder);
		truncated.sink.headers(200);
		truncated.sink.chunk(bytes(event("content_block_delta", "{\"delta\":{\"type\":\"text_delta\",\"text\":\"x\"}}")));
		truncated.sink.complete();
		check(truncatedRecorder.failure != null && reasonName(truncatedRecorder.reason) == "none", "truncated stream is a failure");

		var cancelled = new FakeTransport();
		var cancelledRecorder = new Recorder();
		var handle = new AnthropicProvider(cancelled, "k").start(request, cancelledRecorder);
		handle.cancel();
		cancelled.sink.headers(200);
		cancelled.sink.chunk(bytes(event("message_stop", "{}")));
		check(cancelled.cancelled && reasonName(cancelledRecorder.reason) == "none" && cancelledRecorder.failure == null, "cancel silences the sink");
	}

	static function main():Void {
		sse();
		schemaAndMessages();
		plainReply();
		toolRoundTrip();
		badCalls();
		policies();
		abortKeepsHistoryValid();
		modelSwitch();
		failuresAndLimits();
		sessions();
		anthropicBody();
		anthropicStream();
		Sys.println("agentkit: " + checks + " checks passed");
	}
}
