import haxe.io.Bytes;
import std.fs.Files;
import std.process.Child;
import std.process.Command;
import std.process.Environment;
import std.process.ExitStatus;
import std.process.ProcessError;

// std.process starts programs and reads what they write: each stream piped, inherited or discarded, the environment and
// working directory set per command, waits with a timeout, and every failure a ProcessError. The children are this program
// again, started in a mode its first argument names, so the test is the same on every system.

function failure<T>(result:Result<T, ProcessError>):String
	return switch result {
		case Ok(_): "ok";
		case Err(error): error.describe();
	}

/** This program, started again in `mode`. */
function self(mode:String):Command {
	var program = Environment.programPath().toString(), executable = Environment.executablePath().toString();
	var command = StringTools.endsWith(program, ".hl") ? new Command(executable).arg(program) : new Command(program);
	return command.arg(mode);
}

/** What a child does, by its mode. */
function child(mode:String, rest:Array<String>):Int {
	switch mode {
		case "print":
			Sys.print(rest.join(" "));
			Sys.stderr().writeString("to stderr");
			return 0;
		case "exit":
			return Std.parseInt(rest[0]) ?? 99;
		case "echo-input":
			var input = Sys.stdin().readAll();
			Sys.print("[" + input.toString() + "]");
			return 0;
		case "env":
			var value = Environment.variable(rest[0]);
			Sys.print(value == null ? "<unset>" : value);
			return 0;
		case "cwd":
			Sys.print(Files.workingDirectory().toString());
			return 0;
		case "flood":
			// More than a pipe holds, on both streams: a reader that drained one stream before the other would deadlock.
			var block = Bytes.alloc(1 << 20);
			block.fill(0, block.length, "o".code);
			Sys.stdout().writeBytes(block, 0, block.length);
			block.fill(0, block.length, "e".code);
			Sys.stderr().writeBytes(block, 0, block.length);
			return 0;
		case "sleep":
			Sys.sleep(30);
			return 0;
		case _:
			return 99;
	}
}

function running():Int {
	var printed = self("print").arg("hello").arg("two words").output().unwrap();
	if (!printed.succeeded() || printed.stdoutText() != "hello two words" || printed.stderrText() != "to stderr")
		return 1;
	switch self("exit").arg("3").status() {
		case Ok(Exited(3)):
		case _: return 2;
	}
	var silent = self("print").arg("quiet").stdout(Discard).output().unwrap();
	if (silent.stdout.length != 0 || silent.stderrText() != "to stderr")
		return 3;
	var flood = self("flood").output(60).unwrap();
	if (flood.stdout.length != 1 << 20 || flood.stderr.length != 1 << 20 || flood.stdout.get(5) != "o".code)
		return 4;
	return 0;
}

function input():Int {
	var child = self("echo-input").stdin(Pipe).stdout(Pipe).spawn().unwrap();
	var stdin = child.stdin, stdout = child.stdout;
	if (stdin == null || stdout == null || child.stderr != null)
		return 10;
	// No newline: the child prints through the C runtime, whose text-mode stdout writes one as "\r\n" on Windows.
	stdin.writeText("line one;").unwrap();
	stdin.write(Bytes.ofString("xx-two-xx"), 3, 3).unwrap();
	stdin.close();
	if (stdout.readText().unwrap() != "[line one;two]" || !child.wait().unwrap().succeeded())
		return 11;
	child.close();
	// Output()'s input is empty unless set otherwise.
	if (self("echo-input").output().unwrap().stdoutText() != "[]")
		return 12;
	return 0;
}

function environment():Int {
	var name = "STD_PROCESS_TEST_VALUE";
	Environment.setVariable(name, "inherited");
	if (Environment.variable(name) != "inherited" || Environment.variables().get(name) != "inherited")
		return 20;
	if (self("env").arg(name).output().unwrap().stdoutText() != "inherited")
		return 21;
	if (self("env").arg(name).env(name, "set").output().unwrap().stdoutText() != "set")
		return 22;
	if (self("env").arg(name).removeEnv(name).output().unwrap().stdoutText() != "<unset>")
		return 23;
	if (self("env").arg(name).clearEnv().env(name, "alone").output().unwrap().stdoutText() != "alone")
		return 24;
	Environment.removeVariable(name);
	if (Environment.variable(name) != null || self("env").arg(name).output().unwrap().stdoutText() != "<unset>")
		return 25;
	return 0;
}

function directories():Int {
	Files.removeTree("out/std-process").unwrap();
	Files.createDirectory("out/std-process/inside").unwrap();
	var inside = Files.canonical("out/std-process/inside").unwrap().toString();
	var reported = self("cwd").directory(inside).output().unwrap().stdoutText();
	if (Files.canonical(reported).unwrap().toString() != inside)
		return 30;
	var before = Files.workingDirectory().toString();
	if (!Files.setWorkingDirectory("out/std-process/missing").match(Err(NotFound))
		|| Files.workingDirectory().toString() != before)
		return 31;
	Files.setWorkingDirectory("out/std-process/inside").unwrap();
	var moved = Files.canonical(Files.workingDirectory()).unwrap().toString();
	Files.setWorkingDirectory(before).unwrap();
	if (moved != inside)
		return 32;
	Files.removeTree("out/std-process").unwrap();
	return 0;
}

function failures():Int {
	if (failure(new Command("std-process-no-such-program").spawn()) != "program not found")
		return 40;
	if (failure(self("print").directory("out/std-process-missing").spawn()) != "working directory not found")
		return 41;
	var threw = false;
	try
		new Command("")
	catch (error:haxe.Exception)
		threw = true;
	return threw ? 0 : 42;
}

function stopping():Int {
	var sleeper = self("sleep").stdin(Pipe).spawn().unwrap();
	if (sleeper.pid <= 0 || sleeper.exitStatus() != null)
		return 50;
	if (failure(sleeper.wait(0.2)) != "timed out")
		return 51;
	sleeper.terminate();
	var ended = sleeper.wait(30).unwrap();
	var windows = Sys.systemName() == "Windows";
	if (windows ? ended.succeeded() : !ended.match(Signaled(15)))
		return 52;
	sleeper.close();
	sleeper.close();
	var threw = false;
	try
		sleeper.kill()
	catch (error:haxe.Exception)
		threw = true;
	if (!threw || !sleeper.isClosed())
		return 54;
	var killed = self("sleep").spawn().unwrap();
	killed.kill();
	if (!(windows ? !killed.wait(30).unwrap().succeeded() : killed.wait(30).unwrap().match(Signaled(9))))
		return 55;
	killed.close();
	// A scoped child still running at the end of its scope is ended and reaped.
	{
		scoped var dropped = self("sleep").spawn().unwrap();
		if (dropped.exitStatus() != null)
			return 56;
	}
	// Writing to a child that has exited: on Windows a write is queued for the pipe, so the failure comes with a later one.
	var gone = self("exit").arg("0").stdin(Pipe).spawn().unwrap(), stdin = gone.stdin;
	if (stdin == null)
		return 53;
	while (gone.exitStatus() == null)
		Sys.sleep(0.01);
	var refused = "ok", chunk = Bytes.alloc(65536);
	for (_ in 0...100) {
		refused = failure(stdin.write(chunk));
		if (refused != "ok")
			break;
		Sys.sleep(0.01);
	}
	gone.close();
	if (refused != "the process no longer reads its input")
		return 53;
	switch self("sleep").output(0.2) {
		case Err(TimedOut):
		case _: return 57;
	}
	return 0;
}

function main():Int {
	var arguments = Environment.arguments();
	if (arguments.length > 0)
		return child(arguments[0], arguments.slice(1));
	var failed = 0;
	for (step in [running, input, environment, directories, failures, stopping])
		if (failed == 0)
			failed = step();
	return failed == 0 ? 42 : failed;
}
