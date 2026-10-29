# haxeon-agentkit

A headless agent runtime for applications written in Haxeon. The host owns the
UI, the tools and the permissions; agentkit runs the loop: model call, tool
calls, tool results, repeat.

```haxe
var agent = new Agent(new AgentOptions(
	new AnthropicProvider(transport, apiKey), "claude-sonnet-5-5", "You help design machines.",
	[new SearchProjectTool(), new ModifySceneTool()], new SupervisedPolicy()));
agent.onEvent = function(event) switch event {
	case TextDelta(text): ui.append(text);
	case ApprovalRequested(call, summary): ui.confirm(summary, allow -> agent.resolveApproval(call.id, allow));
	case RunEnded(reason): ui.finish(reason);
	default:
};
agent.send("Find all unused assets in this project");
```

## Design

- **No threads, no async.** Everything is callback-driven on the host's thread.
  The agent holds no timers; responses arrive through the transport's sink, and
  tools complete through a `done` callback, so a tool may wait for a frame or a
  background job.
- **Transport is a host service.** `HttpTransport` is one streaming-POST
  interface. `haxeon-agentkit-nativekit` implements it on NativeKit HTTP
  (desktop). A web host implements it on `fetch`. Nothing else in the package
  touches the platform.
- **Providers are replaceable.** `ModelProvider` turns a `ModelRequest` into
  sink callbacks. `AnthropicProvider` ships today; `ScriptedProvider` makes
  loops deterministic in tests and offline.
- **The host decides what the model may do.** Every tool call goes through a
  `ToolPolicy`: `Allow`, `Deny`, or `Ask`, which pauses the run and emits
  `ApprovalRequested`. `ToolAccess` (`ReadOnly` / `Mutating`) lets a policy be
  one line.
- **Histories stay valid.** Aborting mid-run records every unfinished tool call
  as aborted, so the next request is never rejected for a dangling `tool_use`.
- **JSON is typed at the edge.** `JsonObject` is the only place that touches
  untyped values; conversations serialise through `Message.toJson` and
  `Agent.snapshot()` / `restore()`.

## Writing a tool

```haxe
class OpenDocumentTool extends AgentTool {
	public function new()
		super("open_document", "Open a document by id", new ToolSchema().string("id", "Document id"), Mutating);

	override function summarize(input:JsonObject):String
		return "Open " + input.string("id");

	override function execute(input:JsonObject, context:ToolContext, done:ToolResult->Void):Void
		done(ToolResult.ok(app.open(input.string("id"))));
}
```

Prefer coarse, semantic tools over exposing raw internals; the model does best
when a tool name says what a user would say.

## Tests

```sh
./scripts/haxeon build --project packages/agentkit/tests/haxeon.json
LD_LIBRARY_PATH=out:.tools/hashlink .tools/hashlink/hl packages/agentkit/tests/build/host/main.hl
```

The NativeKit transport needs the native library, so its live test runs from
Exosuit (`scripts/test-agentkit-agents.py`).
