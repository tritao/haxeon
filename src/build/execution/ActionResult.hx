package build.execution;

class ActionResult {
	public final id:ActionId;
	public final exitCode:Int;
	public final skipped:Bool;
	public final blocked:Bool;
	public final fingerprint:Null<String>;
	public final message:Null<String>;

	public function new(id:ActionId, exitCode:Int, skipped:Bool, blocked:Bool, ?fingerprint:String, ?message:String) {
		this.id = id;
		this.exitCode = exitCode;
		this.skipped = skipped;
		this.blocked = blocked;
		this.fingerprint = fingerprint;
		this.message = message;
	}

	public function succeeded():Bool
		return !blocked && exitCode == 0;
}

class ExecutionResult {
	public final actions:Array<ActionResult>;
	public final exitCode:Int;
	public final elapsedMs:Float;

	public function new(actions:Array<ActionResult>, elapsedMs:Float = 0) {
		this.actions = actions.copy();
		this.elapsedMs = elapsedMs;
		var failure:Null<Int> = null;
		for (result in actions)
			if (!result.succeeded() && !result.blocked) {
				failure = result.exitCode;
				break;
			}
		this.exitCode = failure == null ? 0 : failure;
	}
}
