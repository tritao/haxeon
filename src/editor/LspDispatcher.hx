package editor;

import haxe.Json;
import sys.thread.Condition;
import sys.thread.Lock;
import sys.thread.Thread;

private typedef LspDispatchTask = {
	final message:String;
	final stop:Bool;
}

/**
	Keeps protocol state on one worker while allowing the reader thread to deliver
	cancellation notifications immediately.
**/
class LspDispatcher {
	final protocol:LspProtocol;
	final emit:String->Void;
	final capacity:Int;
	final queue:Array<LspDispatchTask> = [];
	final available = new Condition();
	final stopped = new Lock();
	var finished = false;

	public function new(protocol:LspProtocol, emit:String->Void, capacity:Int = 64) {
		if (capacity < 1)
			throw "LSP dispatcher capacity must be positive";
		this.protocol = protocol;
		this.emit = emit;
		this.capacity = capacity;
		Thread.create(run);
	}

	/** Enqueue one message. Returns true when it is an exit notification. */
	public function dispatch(message:String):Bool {
		if (finished)
			return false;
		var method = messageMethod(message);
		if (method == "$/cancelRequest") {
			protocol.handle(message);
			return false;
		}
		enqueue({message: message, stop: false});
		return method == "exit";
	}

	/** Stop after all previously submitted messages have completed. */
	public function finish():Void {
		if (finished)
			return;
		finished = true;
		enqueue({message: "", stop: true});
		stopped.wait();
	}

	function run():Void {
		while (true) {
			var task = dequeue();
			if (task.stop)
				break;
			for (response in protocol.handle(task.message))
				emit(response);
			if (protocol.shouldExit())
				break;
		}
		stopped.release();
	}

	function enqueue(task:LspDispatchTask):Void {
		available.acquire();
		while (queue.length >= capacity)
			available.wait();
		queue.push(task);
		available.broadcast();
		available.release();
	}

	function dequeue():LspDispatchTask {
		available.acquire();
		while (queue.length == 0)
			available.wait();
		var task = queue.shift();
		available.broadcast();
		available.release();
		return task;
	}

	static function messageMethod(message:String):Null<String> {
		try {
			var parsed:Dynamic = Json.parse(message),
				method:Dynamic = Reflect.field(parsed, "method");
			return Std.isOfType(method, String) ? cast method : null;
		} catch (_:Dynamic) {
			return null;
		}
	}
}
