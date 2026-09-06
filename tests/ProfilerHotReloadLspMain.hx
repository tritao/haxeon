import editor.LspDispatcher;
import editor.LspProtocol;
import haxe.Json;
import sys.thread.Lock;
import sys.thread.Mutex;

class ProfilerHotReloadLspMain {
	static function main():Void {
		var args = Sys.args(), port = args.length == 1 ? Std.parseInt(args[0]) : null;
		if (port == null)
			throw "Usage: profiler-hot-reload-lsp-test.hl PORT";
		var messages:Array<String> = [], mutex = new Mutex(), available = new Lock(), protocol = new LspProtocol(),
			dispatcher = new LspDispatcher(protocol, message -> {
				mutex.acquire();
				messages.push(message);
				mutex.release();
				available.release();
			}, 16, 20);
		try {
			dispatcher.dispatch(command(1, "haxeon.profiler.connect", {port: port, timeoutSeconds: 3.0, leafCapacity: 64, maxEntries: 500}));
			var connected = waitFor(messages, mutex, available, value -> value.id == 1);
			if (Reflect.hasField(connected, "error"))
				throw Json.stringify(connected);
			dispatcher.dispatch(command(2, "haxeon.profiler.start", {sampleRate: 250, pollIntervalMs: 50}));
			var started = waitFor(messages, mutex, available, value -> value.id == 2);
			if (Reflect.hasField(started, "error"))
				throw Json.stringify(started);
			if (started.result.metadataSchema != 4)
				throw "Hot-reload profiling requires metadata schema 4";
			var changed = waitFor(messages, mutex, available, value -> value.method == "haxeon/profilerMetadataChanged");
			if (changed.params.oldRevision != 1 || changed.params.newRevision != 2)
				throw "Profiler reported the wrong module revision transition";
			var moduleId:String = changed.params.moduleId;
			var snapshot = waitFor(messages, mutex, available, value -> {
				if (value.method != "haxeon/profilerSnapshot" || value.params.unresolvedFrames != 0)
					return false;
				var oldFound = false, newFound = false;
				for (aggregate in cast(value.params.functions, Array<Dynamic>)) {
					if (StringTools.startsWith(aggregate.key, moduleId + ":1:")) oldFound = true;
					if (StringTools.startsWith(aggregate.key, moduleId + ":2:")) newFound = true;
				}
				return oldFound && newFound;
			});
			if (snapshot.params.metadataChanges.length == 0)
				throw "Snapshot omitted revision history";
			dispatcher.dispatch(command(3, "haxeon.profiler.pause", {}));
			var paused = waitFor(messages, mutex, available, value -> value.id == 3);
			if (paused.result.unresolvedFrames != 0)
				throw "Hot reload produced unresolved profiler frames";
			dispatcher.dispatch(command(4, "haxeon.profiler.disconnect", {}));
			waitFor(messages, mutex, available, value -> value.id == 4);
		} catch (error:Dynamic) {
			dispatcher.finish();
			throw error;
		}
		dispatcher.finish();
		Sys.println("PASS: realtime profiling retained attribution across hot reload");
	}

	static function waitFor(messages:Array<String>, mutex:Mutex, available:Lock, predicate:Dynamic->Bool):Dynamic {
		var deadline = Sys.time() + 16.0, index = 0;
		while (Sys.time() < deadline) {
			mutex.acquire();
			var pending = messages.slice(index);
			index = messages.length;
			mutex.release();
			for (message in pending) {
				var parsed:Dynamic = Json.parse(message);
				if (predicate(parsed))
					return parsed;
			}
			available.wait(deadline - Sys.time());
		}
		throw "Timed out waiting for hot-reload profiler data";
	}

	static function command(id:Int, name:String, options:Dynamic):String
		return Json.stringify({jsonrpc: "2.0", id: id, method: "workspace/executeCommand", params: {command: name, arguments: [options]}});
}
