import editor.lsp.LspDispatcher;
import editor.lsp.LspProtocol;
import haxe.Json;
import sys.thread.Lock;
import sys.thread.Mutex;

class ProfilerLspMain {
	static function main():Void {
		var args = Sys.args(),
			port = args.length == 1 ? Std.parseInt(args[0]) : null;
		if (port == null)
			throw "Usage: profiler-lsp-test.hl PORT";
		var messages:Array<String> = [],
			mutex = new Mutex(),
			available = new Lock(),
			protocol = new LspProtocol(),
			dispatcher = new LspDispatcher(protocol, message -> {
				mutex.acquire();
				messages.push(message);
				mutex.release();
				available.release();
			}, 16, 20);
		try {
			dispatcher.dispatch(request(1, "initialize", {}));
			var initialized = waitFor(messages, mutex, available, value -> value.id == 1);
			var commands:Array<Dynamic> = initialized.result.capabilities.executeCommandProvider.commands;
			if (commands.length != 9)
				throw "Profiler commands were not advertised";

			dispatcher.dispatch(command(2, "haxeon.profiler.connect", {port: port, timeoutSeconds: 3.0, leafCapacity: 32}));
			var connected = waitFor(messages, mutex, available, value -> value.id == 2);
			if (connected.result.state != "connected")
				throw "Profiler did not connect";

			dispatcher.dispatch(command(3, "haxeon.profiler.start", {sampleRate: 250, allocationInterval: 1024, pollIntervalMs: 25}));
			var started = waitFor(messages, mutex, available, value -> value.id == 3);
			if (started.result.state != "running" || started.result.metadataSchema != 4)
				throw "Profiler did not start with schema 4 metadata";
			var capturePath = "out/profiler-lsp-test.hlpc";
			dispatcher.dispatch(command(6, "haxeon.profiler.captureStart", {path: capturePath}));
			if (!waitFor(messages, mutex, available, value -> value.id == 6).result.captureActive)
				throw "Profiler capture did not start";
			var notification = waitFor(messages, mutex, available,
				value -> value.method == "haxeon/profilerSnapshot"
					&& value.params.samples > 0
					&& value.params.timeline.samples.length > 0);
			if (notification.params.view != null || notification.params.stacks != null || notification.params.leaves != null)
				throw "Incremental profiler notification repeated full snapshot data";
			dispatcher.dispatch(command(8, "haxeon.profiler.snapshot", {}));
			var full = waitFor(messages, mutex, available, value -> value.id == 8).result;
			var leaf = full.leaves[0];
			if (leaf.pc == null || leaf.offset == null || leaf.opcodeIndex == null || leaf.file == null)
				throw "Profiler notification omitted raw leaf metadata";
			if (full.view.callTree.length == 0
				|| full.view.flameGraph.length == 0
				|| notification.params.viewDelta.nodes.length == 0
				|| full.view.health.bufferCapacity == "0")
				throw "Profiler notification omitted incremental editor view data";
			var locatedFrame = false;
			for (stack in cast(full.stacks, Array<Dynamic>))
				for (frame in cast(stack.frameDetails, Array<Dynamic>))
					if (frame.file != null && frame.line != null)
						locatedFrame = true;
			if (!locatedFrame)
				throw "Profiler stack frames omitted source navigation metadata";
			if (notification.params.sampleRecords == "0"
				|| notification.params.generatedBytes == "0"
				|| notification.params.overheadMicrosPerSample <= 0
				|| notification.params.threads.length == 0
				|| notification.params.gcStats.length == 0
				|| notification.params.timeline.samples.length == 0
				|| notification.params.timeline.stacks.length == 0
				|| notification.params.timeline.allocations.length == 0)
				throw "Profiler snapshot omitted calibration or thread telemetry";
			dispatcher.dispatch(command(7, "haxeon.profiler.captureStop", {}));
			if (waitFor(messages, mutex, available, value -> value.id == 7).result.captureActive || !sys.FileSystem.exists(capturePath))
				throw "Profiler capture did not finalize";

			dispatcher.dispatch(command(4, "haxeon.profiler.pause", {}));
			var paused = waitFor(messages, mutex, available, value -> value.id == 4);
			if (paused.result.state != "paused" || paused.result.functions.length == 0 || paused.result.stacks.length == 0)
				throw "Paused profiler snapshot omitted aggregates";
			dispatcher.dispatch(command(5, "haxeon.profiler.disconnect", {}));
			if (waitFor(messages, mutex, available, value -> value.id == 5).result.state != "disconnected")
				throw "Profiler did not disconnect";
		} catch (error:Dynamic) {
			dispatcher.finish();
			throw error;
		}
		dispatcher.finish();
		Sys.println("PASS: LSP profiler commands stream structured snapshots");
	}

	static function waitFor(messages:Array<String>, mutex:Mutex, available:Lock, predicate:Dynamic->Bool):Dynamic {
		var deadline = Sys.time() + 5.0;
		while (Sys.time() < deadline) {
			mutex.acquire();
			for (message in messages) {
				var parsed:Dynamic = Json.parse(message);
				if (predicate(parsed)) {
					mutex.release();
					return parsed;
				}
			}
			mutex.release();
			available.wait(deadline - Sys.time());
		}
		throw "Timed out waiting for LSP profiler message";
	}

	static function request(id:Int, method:String, params:Dynamic):String
		return Json.stringify({
			jsonrpc: "2.0",
			id: id,
			method: method,
			params: params
		});

	static function command(id:Int, name:String, options:Dynamic):String
		return request(id, "workspace/executeCommand", {command: name, arguments: [options]});
}
