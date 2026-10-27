package haxeon.agent;

/**
	Headless agent loop: model, tool calls, tool results, repeat. The host owns
	the UI, the tools and the policy. All callbacks and events arrive on the
	host's thread; the agent never blocks and holds no timers, so a host that
	drives its own event pump needs nothing more than the transport's callbacks.
**/
class Agent {
	/** Receives every event. Set before `send`. */
	public var onEvent:AgentEvent->Void = function(_) {};

	public var state(default, null):AgentState = Idle;

	/** Model for subsequent turns. A run in progress keeps the model it started its current turn with. */
	public var model:String;

	final options:AgentOptions;
	final history:Array<Message> = [];
	var run = 0;
	var turn = 0;
	var inflight:Null<Cancelable>;
	var batch:Null<ToolBatch>;

	public function new(options:AgentOptions) {
		this.options = options;
		model = options.model;
	}

	public function messages():Array<Message>
		return history.copy();

	/** Starts a run for `text`. Returns false when a run is already active. */
	public function send(text:String):Bool {
		if (state != Idle)
			return false;
		history.push(Message.user(text));
		run++;
		turn = 0;
		emit(RunStarted);
		startTurn();
		return true;
	}

	/** Stops the active run. Tool calls that have not finished are recorded as aborted so the history stays valid. */
	public function abort():Void {
		if (state == Idle)
			return;
		var activeRun = run;
		run++;
		if (inflight != null) {
			inflight.cancel();
			inflight = null;
		}
		var pending = batch;
		batch = null;
		if (pending != null) {
			while (pending.next < pending.calls.length) {
				var call = pending.calls[pending.next++];
				pending.results.push(ToolOutput(call.id, "Aborted by the user", true));
			}
			history.push(new Message(User, pending.results));
		}
		state = Idle;
		emit(RunEnded(Aborted));
	}

	/** Answers an ApprovalRequested event. Unknown or stale ids are ignored. */
	public function resolveApproval(callId:String, allow:Bool):Void {
		var current = batch;
		if (state != AwaitingApproval || current == null || current.calls[current.next].id != callId)
			return;
		if (allow)
			execute(current, run);
		else
			finishCall(current, run, ToolResult.error("The user declined this tool call"));
	}

	function emit(event:AgentEvent):Void
		onEvent(event);

	function end(reason:StopReason):Void {
		state = Idle;
		inflight = null;
		emit(RunEnded(reason));
	}

	function startTurn():Void {
		if (turn >= options.maxTurns) {
			end(Failed("Stopped after " + options.maxTurns + " model turns"));
			return;
		}
		turn++;
		state = Streaming;
		emit(TurnStarted(turn));
		var specs = [for (tool in options.tools) new ToolSpec(tool.name, tool.description, tool.schema.toJson())];
		var request = new ModelRequest(model, options.system, history.copy(), specs, options.maxTokens);
		inflight = options.provider.start(request, new TurnSink(run, turnText, turnCompleted, turnFailed));
	}

	function turnText(token:Int, delta:String):Void {
		if (token == run)
			emit(TextDelta(delta));
	}

	function turnFailed(token:Int, message:String):Void {
		if (token != run)
			return;
		end(Failed(message));
	}

	function turnCompleted(token:Int, text:String, calls:Array<ToolCall>, reason:StopReason):Void {
		if (token != run)
			return;
		inflight = null;
		var blocks:Array<ContentBlock> = [];
		if (text != "")
			blocks.push(Text(text));
		for (call in calls)
			blocks.push(ToolUse(call.id, call.name, call.inputJson));
		if (blocks.length > 0) {
			var message = new Message(Assistant, blocks);
			history.push(message);
			emit(MessageCompleted(message));
		}
		if (calls.length == 0) {
			end(reason);
			return;
		}
		batch = new ToolBatch(calls);
		nextCall(batch, token);
	}

	function nextCall(current:ToolBatch, token:Int):Void {
		if (current.next >= current.calls.length) {
			batch = null;
			history.push(new Message(User, current.results));
			startTurn();
			return;
		}
		var call = current.calls[current.next];
		var tool = findTool(call.name);
		if (tool == null) {
			finishCall(current, token, ToolResult.error("Unknown tool: " + call.name));
			return;
		}
		var input = JsonObject.parse(call.inputJson);
		if (input == null) {
			finishCall(current, token, ToolResult.error("Tool arguments were not a valid JSON object"));
			return;
		}
		switch options.policy.decide(tool, input) {
			case Allow:
				execute(current, token);
			case Deny(reason):
				finishCall(current, token, ToolResult.error("Not allowed: " + reason));
			case Ask:
				state = AwaitingApproval;
				emit(ApprovalRequested(call, tool.summarize(input)));
		}
	}

	function execute(current:ToolBatch, token:Int):Void {
		var call = current.calls[current.next];
		var tool = findTool(call.name);
		var input = JsonObject.parse(call.inputJson);
		if (tool == null || input == null) {
			finishCall(current, token, ToolResult.error("Tool call is no longer valid"));
			return;
		}
		state = RunningTool;
		emit(ToolStarted(call));
		var completed = false;
		var done = function(result:ToolResult):Void {
			if (completed || token != run)
				return;
			completed = true;
			finishCall(current, token, result);
		};
		try
			tool.execute(input, new ToolContext(call.id), done)
		catch (error:Dynamic)
			done(ToolResult.error("Tool failed: " + Std.string(error)));
	}

	function finishCall(current:ToolBatch, token:Int, result:ToolResult):Void {
		var call = current.calls[current.next++];
		current.results.push(ToolOutput(call.id, result.content, result.isError));
		emit(ToolCompleted(call, result));
		nextCall(current, token);
	}

	function findTool(name:String):Null<AgentTool> {
		for (tool in options.tools)
			if (tool.name == name)
				return tool;
		return null;
	}

	public function snapshot():String
		return JsonWriter.object([
			JsonWriter.field("version", "1"),
			JsonWriter.field("messages", JsonWriter.array([for (message in history) message.toJson()]))
		]);

	/** Replaces the conversation from `snapshot` output. Fails, leaving the history unchanged, on bad input or while running. */
	public function restore(json:String):Bool {
		if (state != Idle)
			return false;
		var root = JsonObject.parse(json);
		if (root == null || root.int("version") != 1)
			return false;
		var restored:Array<Message> = [];
		for (item in root.objects("messages")) {
			var message = Message.fromJson(item);
			if (message == null)
				return false;
			restored.push(message);
		}
		history.resize(0);
		for (message in restored)
			history.push(message);
		return true;
	}
}

private class ToolBatch {
	public final calls:Array<ToolCall>;
	public final results:Array<ContentBlock> = [];
	public var next = 0;

	public function new(calls:Array<ToolCall>)
		this.calls = calls;
}

private class TurnSink implements ModelSink {
	final token:Int;
	final onText:(token:Int, delta:String) -> Void;
	final onComplete:(token:Int, text:String, calls:Array<ToolCall>, reason:StopReason) -> Void;
	final onFail:(token:Int, message:String) -> Void;
	final calls:Array<ToolCall> = [];
	var buffer = "";

	public function new(token:Int, onText:(token:Int, delta:String) -> Void,
			onComplete:(token:Int, text:String, calls:Array<ToolCall>, reason:StopReason) -> Void, onFail:(token:Int, message:String) -> Void) {
		this.token = token;
		this.onText = onText;
		this.onComplete = onComplete;
		this.onFail = onFail;
	}

	public function text(delta:String):Void {
		buffer += delta;
		onText(token, delta);
	}

	public function toolUse(call:ToolCall):Void
		calls.push(call);

	public function complete(reason:StopReason):Void
		onComplete(token, buffer, calls, reason);

	public function fail(message:String):Void
		onFail(token, message);
}
