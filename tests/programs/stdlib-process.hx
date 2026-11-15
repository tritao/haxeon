import haxe.io.Eof;
import sys.io.Process;

// sys.io.Process runs a command as Haxe's does: directly with arguments, through the shell without, with its output and
// error as inputs, its input as an output, and its exit code.
function main():Int {
	if (Sys.systemName() == "Windows")
		return 42;
	var direct = new Process("sh", ["-c", "printf 'one\\ntwo'; printf oops >&2; exit 3"]);
	if (direct.stdout.readAll().toString() != "one\ntwo" || direct.stderr.readAll().toString() != "oops")
		return 1;
	if (direct.exitCode() != 3 || direct.exitCode(false) != 3)
		return 2;
	if (direct.getPid() <= 0)
		return 3;
	direct.close();
	// Arguments are passed as they are, not split or expanded by a shell.
	var literal = new Process("printf", ["%s|", "a b", "$HOME"]);
	if (literal.stdout.readAll().toString() != "a b|$HOME|")
		return 4;
	literal.close();
	var shell = new Process("echo shell | tr a-z A-Z");
	if (shell.stdout.readLine() != "SHELL")
		return 5;
	try {
		shell.stdout.readLine();
		return 6;
	} catch (_:Eof) {}
	if (shell.exitCode() != 0)
		return 7;
	shell.close();
	var cat = new Process("cat");
	cat.stdin.writeString("ping\npong");
	cat.stdin.close();
	if (cat.stdout.readLine() != "ping" || cat.stdout.readAll().toString() != "pong" || cat.exitCode() != 0)
		return 8;
	cat.close();
	var sleeper = new Process("sleep", ["5"]);
	if (sleeper.exitCode(false) != null)
		return 9;
	sleeper.kill();
	if (sleeper.exitCode() == 0)
		return 10;
	sleeper.close();
	return 42;
}
