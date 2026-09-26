package build.execution;

import haxe.io.Bytes;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;
import sys.io.Process;
#if (target.threaded && !eval)
import sys.thread.Lock;
import sys.thread.Mutex;
import sys.thread.Thread;
#end

/** The only build-layer boundary that starts external processes. */
class ProcessRunner {
	static var waveCounter = 0;

	#if (target.threaded && !eval)
	static final launchMutex = new Mutex();
	#end

	public static function run(command:String, arguments:Array<String>, cwd:String, environment:Map<String, String>, forwardOutput:Bool = true):Int {
		#if (target.threaded && !eval)
		var previousDirectory = Sys.getCwd(),
			oldEnvironment = new Map<String, Null<String>>(),
			process:Process = null;
		launchMutex.acquire();
		try {
			if (cwd != null
				&& cwd != ""
				&& Path.normalize(FileSystem.fullPath(cwd)) != Path.normalize(FileSystem.fullPath(previousDirectory)))
				Sys.setCwd(cwd);
			if (environment != null)
				for (key in environment.keys()) {
					oldEnvironment.set(key, Sys.getEnv(key));
					Sys.putEnv(key, environment.get(key));
				}
			process = new Process(command, arguments);
		} catch (error:Dynamic) {
			restore(previousDirectory, oldEnvironment);
			launchMutex.release();
			throw 'Could not start $command: ${Std.string(error)}';
		}
		restore(previousDirectory, oldEnvironment);
		launchMutex.release();

		var readers = new Lock();
		Thread.create(function() {
			copyOutput(process.stdout, forwardOutput ? Sys.stdout() : null);
			readers.release();
		});
		Thread.create(function() {
			copyOutput(process.stderr, forwardOutput ? Sys.stderr() : null);
			readers.release();
		});
		var status = process.exitCode();
		readers.wait();
		readers.wait();
		process.close();
		return status == null ? 1 : status;
		#else
		var previousDirectory = Sys.getCwd(), oldEnvironment = new Map<String, Null<String>>(), status = 1;
		var failure:Dynamic = null;
		try {
			if (cwd != null
				&& cwd != ""
				&& Path.normalize(FileSystem.fullPath(cwd)) != Path.normalize(FileSystem.fullPath(previousDirectory)))
				Sys.setCwd(cwd);
			if (environment != null)
				for (key in environment.keys()) {
					oldEnvironment.set(key, Sys.getEnv(key));
					Sys.putEnv(key, environment.get(key));
				}
			if (forwardOutput) {
				status = Sys.command(command, arguments);
			} else {
				var process = new sys.io.Process(command, arguments);
				process.stdout.readAll();
				process.stderr.readAll();
				status = process.exitCode();
				process.close();
			}
		} catch (error:Dynamic) {
			failure = error;
		}
		for (key in oldEnvironment.keys()) {
			var previous = oldEnvironment.get(key);
			Sys.putEnv(key, previous == null ? "" : previous);
		}
		if (Path.normalize(FileSystem.fullPath(Sys.getCwd())) != Path.normalize(FileSystem.fullPath(previousDirectory)))
			Sys.setCwd(previousDirectory);
		if (failure != null)
			throw failure;
		return status;
		#end
	}

	/** Runs a ready process wave concurrently, including eval runtimes with blocking process waits. */
	public static function runConcurrent(tasks:Array<{
		command:String,
		arguments:Array<String>,
		cwd:String,
		environment:Map<String, String>
	}>, workerCount:Int, buildRoot:String):Array<Int> {
		if (tasks.length == 0)
			return [];
		#if (target.threaded && !eval)
		return [
			for (task in tasks)
				run(task.command, task.arguments, task.cwd, task.environment)
		];
		#else
		if (tasks.length == 1 || workerCount <= 1 || (Sys.systemName() != "Linux" && Sys.systemName() != "Mac"))
			return [
				for (task in tasks)
					run(task.command, task.arguments, task.cwd, task.environment)
			];
		var waveDirectory = createWaveDirectory(buildRoot),
			scriptPath = Path.join([waveDirectory, "run.sh"]),
			statuses:Array<Int> = [];
		var script = new StringBuf();
		script.add("#!/bin/sh\nset +e\n");
		for (index in 0...tasks.length) {
			var task = tasks[index], stdoutPath = Path.join([waveDirectory, 'stdout-$index']), stderrPath = Path.join([waveDirectory, 'stderr-$index']),
				statusPath = Path.join([waveDirectory, 'status-$index']), command = [
					for (key in sortedKeys(task.environment))
						shellQuote('$key=${task.environment.get(key)}')
				];
			command.push(shellQuote(task.command));
			for (argument in task.arguments)
				command.push(shellQuote(argument));
			script.add("(\n");
			var cwd = task.cwd == null || task.cwd == "" ? Sys.getCwd() : FileSystem.fullPath(task.cwd);
			script.add('  cd ${shellQuote(cwd)} || exit 126\n');
			script.add('  exec env ${command.join(" ")}\n');
			script.add(') > ${shellQuote(stdoutPath)} 2> ${shellQuote(stderrPath)} &\n');
			script.add('pid_$index=$!\n');
		}
		for (index in 0...tasks.length) {
			var statusPath = Path.join([waveDirectory, 'status-$index']),
				pidVariable = 'pid_$index',
				statusVariable = 'status_$index',
				pidReference = "$" + pidVariable,
				statusReference = "$" + statusVariable;
			script.add('wait "$pidReference"\n');
			script.add('$statusVariable=$?\n');
			script.add('printf \'%s\\n\' "$statusReference" > ${shellQuote(statusPath)}\n');
		}
		script.add("exit 0\n");
		File.saveContent(scriptPath, script.toString());
		var launchFailure:Null<String> = null;
		try {
			run("/bin/sh", [scriptPath], waveDirectory, new Map());
		} catch (error:Dynamic) {
			launchFailure = Std.string(error);
		}
		for (index in 0...tasks.length) {
			var stdoutPath = Path.join([waveDirectory, 'stdout-$index']),
				stderrPath = Path.join([waveDirectory, 'stderr-$index']),
				statusPath = Path.join([waveDirectory, 'status-$index']),
				stdout = FileSystem.exists(stdoutPath) ? File.getBytes(stdoutPath) : Bytes.alloc(0),
				stderr = FileSystem.exists(stderrPath) ? File.getBytes(stderrPath) : Bytes.alloc(0),
				statusText = FileSystem.exists(statusPath) ? StringTools.trim(File.getContent(statusPath)) : "",
				status = launchFailure == null ? Std.parseInt(statusText) : 127;
			if (stdout.length > 0)
				Sys.stdout().writeBytes(stdout, 0, stdout.length);
			if (stderr.length > 0)
				Sys.stderr().writeBytes(stderr, 0, stderr.length);
			if (launchFailure != null)
				Sys.stderr().writeString(launchFailure + "\n");
			else if (status == null) {
				Sys.stderr().writeString('Process batch did not record an exit status for action ${index + 1}\n');
				status = 1;
			}
			statuses.push(status == null ? 1 : status);
		}
		Sys.stdout().flush();
		Sys.stderr().flush();
		removeWaveDirectory(waveDirectory);
		return statuses;
		#end
	}

	public static function capture(command:String, arguments:Array<String>):{status:Int, output:String} {
		try {
			var process = new Process(command, arguments),
				stdout = process.stdout.readAll().toString(),
				stderr = process.stderr.readAll().toString(),
				status = process.exitCode();
			process.close();
			return {status: status == null ? 1 : status, output: stdout + stderr};
		} catch (error:Dynamic) {
			return {status: 127, output: Std.string(error)};
		}
	}

	#if (target.threaded && !eval)
	static function restore(previousDirectory:String, oldEnvironment:Map<String, Null<String>>):Void {
		for (key in oldEnvironment.keys()) {
			var previous = oldEnvironment.get(key);
			Sys.putEnv(key, previous == null ? "" : previous);
		}
		if (Path.normalize(FileSystem.fullPath(Sys.getCwd())) != Path.normalize(FileSystem.fullPath(previousDirectory)))
			Sys.setCwd(previousDirectory);
	}

	static function copyOutput(input:haxe.io.Input, output:Null<haxe.io.Output>):Void {
		try {
			var bytes = Bytes.alloc(8192),
				count = input.readBytes(bytes, 0, bytes.length);
			while (count > 0) {
				if (output != null)
					output.writeBytes(bytes, 0, count);
				count = input.readBytes(bytes, 0, bytes.length);
			}
			if (output != null)
				output.flush();
		} catch (_:Dynamic) {}
	}
	#end

	#if (!target.threaded || eval)
	static function sortedKeys(environment:Map<String, String>):Array<String> {
		var result = [for (key in environment.keys()) key];
		result.sort(Reflect.compare);
		return result;
	}

	static function shellQuote(value:String):String
		return "'" + value.split("'").join("'\\''") + "'";

	static function createWaveDirectory(base:String):String {
		var parent = Path.join([base, ".haxeon", "process-waves"]);
		Directories.ensure(parent);
		while (true) {
			waveCounter++;
			var candidate = Path.join([parent, 'wave-${Std.int(Date.now().getTime())}-$waveCounter']);
			if (FileSystem.exists(candidate))
				continue;
			try {
				FileSystem.createDirectory(candidate);
				return candidate;
			} catch (_:Dynamic) {
				if (!FileSystem.exists(candidate))
					throw 'Could not create process wave directory $candidate';
			}
		}
		return parent;
	}

	static function removeWaveDirectory(directory:String):Void {
		for (entry in FileSystem.readDirectory(directory)) {
			var path = Path.join([directory, entry]);
			if (FileSystem.exists(path) && !FileSystem.isDirectory(path))
				FileSystem.deleteFile(path);
		}
		FileSystem.deleteDirectory(directory);
	}
	#end
}
