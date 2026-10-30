package build.native;

import haxe.io.Bytes;
import sys.io.Process;

/** Runs a short host command, such as a tool's version query, and reads what it printed. */
class HostCommand {
	/**
	 * Standard output of a command that exited with status 0, or null when it failed or could not start. With `arguments`
	 * null the command line goes to the shell (`cmd /C` on Windows).
	 */
	public static function output(command:String, arguments:Null<Array<String>>):Null<Bytes> {
		return try {
			var process = new Process(command, arguments),
				bytes = process.stdout.readAll(),
				status = process.exitCode();
			process.close();
			status == 0 ? bytes : null;
		} catch (_:Dynamic) null;
	}

	/** `output` as trimmed UTF-8 text without carriage returns. */
	public static function text(command:String, arguments:Null<Array<String>>):Null<String> {
		var bytes = output(command, arguments);
		return bytes == null ? null : StringTools.trim(StringTools.replace(bytes.toString(), "\r", ""));
	}
}
