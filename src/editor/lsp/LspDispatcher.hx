package editor.lsp;

import haxe.Json;
import sys.thread.Condition;
import sys.thread.Lock;
import sys.thread.Thread;

private typedef LspDispatchTask = {
	final message:String;
	final diagnostics:Bool;
	final workspaceIndex:Bool;
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
	var workspaceIndexScheduled = false;
	var diagnosticsPending = false;
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
		var requestId = messageId(message),
			foregroundRequest = requestId != null
				&& method != "textDocument/semanticTokens/full"
				&& method != "textDocument/semanticTokens/full/delta",
			resumeDiagnostics = changesDocument || foregroundRequest && hasDiagnosticsPending(),
			workspaceChanged = method == "initialize"
				|| changesDocument
				|| method == "workspace/didChangeConfiguration"
				|| method == "workspace/didChangeWorkspaceFolders";
		if (resumeDiagnostics)
			protocol.cancelPendingDiagnostics();
		if (!enqueue({
			message: message,
			submittedAt: Sys.time(),
			diagnostics: false,
			workspaceIndex: false,
			stop: false,
			generation: 0
		}, method != "textDocument/semanticTokens/full" && method != "textDocument/semanticTokens/full/delta"))
			return false;
		if (resumeDiagnostics)
			scheduleDiagnostics();
		if (workspaceChanged)
			scheduleWorkspaceIndex();
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
		diagnosticsPending = false;
		debounceWake.release();
		background.resize(0);
		protocol.cancelPendingDiagnostics();
		while (interactive.length + background.length >= capacity)
			available.wait();
		interactive.push({
			message: "",
			diagnostics: false,
			workspaceIndex: false,
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
				if (task.generation == currentDebounceGeneration()) {
					for (response in protocol.analyzePendingDiagnostics())
						emit(response);
					available.acquire();
					if (task.generation == debounceGeneration)
						diagnosticsPending = false;
					available.broadcast();
					available.release();
				}
				if (protocol.workspaceSymbolsIndexNeedsWork())
					scheduleWorkspaceIndexFromWorker();
			} else if (task.workspaceIndex) {
				if (protocol.indexWorkspaceSymbolsChunk(4))
					enqueueWorkspaceIndexContinuation({
						message: "",
						diagnostics: false,
						workspaceIndex: true,
						stop: false,
						generation: 0
					});
				else {
					available.acquire();
					workspaceIndexScheduled = false;
					available.release();
				}
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
				if (protocol.workspaceSymbolsIndexNeedsWork())
					scheduleWorkspaceIndexFromWorker();
			}
		}
		stopped.release();
	}

	function scheduleDiagnostics():Void {
		available.acquire();
		debounceGeneration++;
		diagnosticsPending = true;
		var index = background.length - 1;
		while (index >= 0) {
			if (background[index].diagnostics)
				background.splice(index, 1);
			index--;
		}
		available.release();
		debounceWake.release();
	}

	function hasDiagnosticsPending():Bool {
		available.acquire();
		var pending = diagnosticsPending;
		available.release();
		return pending;
	}

	function scheduleWorkspaceIndex():Void {
		available.acquire();
		if (finished || workspaceIndexScheduled) {
			available.release();
			return;
		}
		while (!finished && interactive.length + background.length >= capacity)
			available.wait();
		if (finished) {
			available.release();
			return;
		}
		workspaceIndexScheduled = true;
		background.push({
			message: "",
			diagnostics: false,
			workspaceIndex: true,
			stop: false,
			generation: 0
		});
		available.broadcast();
		available.release();
	}

	function scheduleWorkspaceIndexFromWorker():Void {
		available.acquire();
		if (finished || workspaceIndexScheduled) {
			available.release();
			return;
		}
		workspaceIndexScheduled = true;
		background.push({
			message: "",
			diagnostics: false,
			workspaceIndex: true,
			stop: false,
			generation: 0
		});
		available.broadcast();
		available.release();
	}

	function enqueueWorkspaceIndexContinuation(task:LspDispatchTask):Void {
		// The dispatcher worker cannot wait for queue capacity while requeuing its
		// own low-priority slice: it is the only thread that can free capacity.
		// Reserve one extra slot for this single coalesced continuation.
		available.acquire();
		if (!finished)
			background.push(task);
		else
			workspaceIndexScheduled = false;
		available.broadcast();
		available.release();
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
			enqueueDiagnostic({
				message: "",
				diagnostics: true,
				workspaceIndex: false,
				stop: false,
				generation: generation
			});
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

	function enqueueDiagnostic(task:LspDispatchTask):Void {
		// Diagnostics must be able to pass the bounded request queue after an
		// edit, even when low-priority refreshes are already waiting.
		available.acquire();
		if (!finished)
			background.push(task);
		available.broadcast();
		available.release();
	}

	function dequeue():LspDispatchTask {
		available.acquire();
		var task:LspDispatchTask = {message: "", diagnostics: false, workspaceIndex: false, stop: false, generation: 0};
		while (true) {
			if (interactive.length > 0) {
				task = interactive.shift();
				break;
			}
			var diagnosticIndex = -1;
			for (index in 0...background.length)
				if (background[index].diagnostics) {
					diagnosticIndex = index;
					break;
				}
			if (diagnosticIndex >= 0) {
				task = background.splice(diagnosticIndex, 1)[0];
				break;
			}
			if (diagnosticsPending || background.length == 0) {
				available.wait();
				continue;
			}
			// Semantic-token refreshes and debounced diagnostics can unblock the
			// editor, so keep incremental workspace indexing behind those tasks.
			var priority = -1;
			for (index in 0...background.length)
				if (!background[index].workspaceIndex) {
					priority = index;
					break;
				}
			task = priority < 0 ? background.shift() : background.splice(priority, 1)[0];
			break;
		}
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

	static function messageId(message:String):Dynamic {
		try {
			return Reflect.field(Json.parse(message), "id");
		} catch (_:Dynamic) {
			return null;
		}
	}
}
