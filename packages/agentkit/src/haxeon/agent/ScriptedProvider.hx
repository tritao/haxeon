package haxeon.agent;

/** Deterministic provider for tests and offline hosts. Answers synchronously from a queue. */
class ScriptedProvider implements ModelProvider {
	public final requests:Array<ModelRequest> = [];
	final script:Array<ScriptedResponse>;

	public function new(script:Array<ScriptedResponse>)
		this.script = script.copy();

	public function start(request:ModelRequest, sink:ModelSink):Cancelable {
		requests.push(request);
		var response = script.shift();
		if (response == null) {
			sink.fail("Scripted provider has no response left");
		} else if (response.failure != null) {
			sink.fail(response.failure);
		} else {
			if (response.text != "")
				sink.text(response.text);
			for (call in response.calls)
				sink.toolUse(call);
			sink.complete(response.reason);
		}
		return new NoCancel();
	}
}

private class NoCancel implements Cancelable {
	public function new() {}

	public function cancel():Void {}
}
