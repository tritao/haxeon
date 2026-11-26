package haxeon.agent;

/** Deterministic provider for tests and offline hosts. Answers synchronously from a queue. */
class ScriptedProvider implements ModelProvider {
	/** Every request it received, in order. */
	public final requests:Array<ModelRequest> = [];
	final script:Array<ScriptedResponse>;

	/** A provider answering each turn with the next of `script`, and failing once it runs out. */
	public function new(script:Array<ScriptedResponse>)
		this.script = script.copy();

	/** Records `request` and answers with the next scripted response. */
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
