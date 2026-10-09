package editor.lsp;

import haxe.Json;
import sys.thread.Condition;
import sys.thread.Lock;
import sys.thread.Thread;

private typedef LspDispatchTask = {
	final message:String;
	final diagnostics:Bool;
	final stop:Bool;
	final generation:Int;
	final ?submittedAt:Float;
}

/** Ordered compiler lane with immediate cancellation and debounced diagnostics. */
class LspDispatcher {
	final protocol:LspProtocol;
	final emit:String->Void;
	final capacity:Int;
	final debounceSeconds:Float;
	final interactive:Array<LspDispatchTask> = [];
	final background:Array<LspDispatchTask> = [];
	final available = new Condition();
	final debounceWake = new Lock();
	final debounceStopped = new Lock();
	final stopped = new Lock();
	var debounceGeneration = 0;
	var finished = false;

	public function new(protocol:LspProtocol, emit:String->Void, capacity:Int = 64, debounceMs:Int = 150) {
		if (capacity < 1)
			throw "LSP dispatcher capacity must be positive";
		if (debounceMs < 0)
			throw "LSP diagnostic debounce must not be negative";
		this.protocol = protocol;
		this.emit = emit;
		this.capacity = capacity;
		debounceSeconds = debounceMs / 1000.0;
		protocol.enableDeferredDiagnostics();
		protocol.enableProfilerNotifications(emit);
		Thread.create(run);
		Thread.create(runDebounce);
	}

	/** Enqueue one message. Returns true when it is an exit notification. */
	public function dispatch(message:String):Bool {
		var method = messageMethod(message);
		if (method == "$/cancelRequest") {
			protocol.handle(message);
			return false;
		}
		var changesDocument = method == "textDocument/didOpen"
			|| method == "textDocument/didChange"
			|| method == "textDocument/didClose"
			|| method == "workspace/didChangeWatchedFiles";
		var navigation = method == "textDocument/definition" || method == "textDocument/typeDefinition";
		if (changesDocument || navigation)
			protocol.cancelPendingDiagnostics();
		if (!enqueue({
			message: message,
			submittedAt: Sys.time(),
			diagnostics: false,
			stop: false,
			generation: 0
		}, method != "textDocument/semanticTokens/full" && method != "textDocument/semanticTokens/full/delta"))
			return false;
		if (changesDocument || navigation)
			scheduleDiagnostics();
		return method == "exit";
	}

	/** Cancel background work and stop after previously submitted interactive work. */
	public function finish():Void {
		available.acquire();
		if (finished) {
			available.release();
			return;
		}
		finished = true;
		debounceGeneration++;
		debounceWake.release();
		background.resize(0);
		protocol.cancelPendingDiagnostics();
		while (interactive.length + background.length >= capacity)
			available.wait();
		interactive.push({
			message: "",
			diagnostics: false,
			stop: true,
			generation: 0
		});
		available.broadcast();
		available.release();
		stopped.wait();
		debounceStopped.wait();
		protocol.dispose();
	}

	function run():Void {
		while (true) {
			var task = dequeue();
			if (task.stop)
				break;
			if (task.diagnostics) {
				if (task.generation == currentDebounceGeneration())
					for (response in protocol.analyzePendingDiagnostics())
						emit(response);
			} else {
				var started = Sys.time();
				for (response in protocol.handle(task.message))
					emit(response);
				var method = messageMethod(task.message);
				if (method == "textDocument/definition" || method == "textDocument/typeDefinition") {
					var request:Dynamic = Json.parse(task.message);
					emit(Json.stringify({jsonrpc: "2.0", method: "$/haxeon/requestTiming", params: {
						id: Reflect.field(request, "id"), method: method,
						queueMs: task.submittedAt == null ? 0 : (started - task.submittedAt) * 1000,
						analysisMs: protocol.lastForegroundAnalysisMs, executionMs: (Sys.time() - started) * 1000
					}}));
				}
				if (protocol.shouldExit())
					break;
			}
		}
		stopped.release();
	}

	function scheduleDiagnostics():Void {
		available.acquire();
		debounceGeneration++;
		available.release();
		debounceWake.release();
	}

	function runDebounce():Void {
		while (true) {
			debounceWake.wait();
			var done = false;
			while (true) {
				available.acquire();
				done = finished;
				available.release();
				if (done || !debounceWake.wait(debounceSeconds))
					break;
			}
			if (done)
				break;
			available.acquire();
			var generation = debounceGeneration;
			available.release();
			enqueue({
				message: "",
				diagnostics: true,
				stop: false,
				generation: generation
			}, false);
		}
		debounceStopped.release();
	}

	function enqueue(task:LspDispatchTask, highPriority:Bool):Bool {
		available.acquire();
		while (!finished && interactive.length + background.length >= capacity)
			available.wait();
		if (finished) {
			available.release();
			return false;
		}
		(highPriority ? interactive : background).push(task);
		available.broadcast();
		available.release();
		return true;
	}

	function dequeue():LspDispatchTask {
		available.acquire();
		while (interactive.length == 0 && background.length == 0)
			available.wait();
		var task = interactive.length > 0 ? interactive.shift() : background.shift();
		available.broadcast();
		available.release();
		return task;
	}

	function currentDebounceGeneration():Int {
		available.acquire();
		var generation = debounceGeneration;
		available.release();
		return generation;
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
