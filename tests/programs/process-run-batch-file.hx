// Windows: Process.run refuses a .cmd or .bat target instead of starting it. CreateProcess would hand the command line
// to cmd.exe, which parses it again with its own rules, so an argument such as `& exit 7` would run as a command.
function refused(command:String):Bool {
	try {
		var process = sys.io.Process.run(command, ["value with spaces", "==", "value with spaces", "&", "exit", "7"]);
		process.exitCode();
		process.close();
		return false;
	} catch (_:Dynamic)
		return true;
}

function main():Int {
	if (Sys.systemName() != "Windows")
		return 42;
	// The script exists (sys-runtime runs it through `cmd /C call`), so only the refusal can make these fail to start.
	for (command in [
		"tests\\programs\\sys-command-args.cmd",
		"tests\\programs\\SYS-COMMAND-ARGS.CMD",
		"tests\\programs\\sys-command-args.cmd.",
		"tests\\programs\\sys-command-args.cmd "
	])
		if (!refused(command))
			return 1;
	// An executable still starts.
	var process = sys.io.Process.run("whoami.exe", []);
	process.readStdout();
	process.readStderr();
	var code = process.exitCode();
	process.close();
	return code + 42;
}
