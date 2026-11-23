import compiler.core.InternalError;
import editor.lsp.LspDispatcher;
import editor.lsp.LspProtocol;
import haxe.io.Bytes;
import haxe.io.Eof;

/** Standard Language Server Protocol entry point over stdio: `haxeon lsp`. */
class LspMain {
	static function main():Void
		run(Sys.args());

	/**
	 * Serves one client on standard input and output until it exits. `--stdlib=PATH` names the standard library, as `haxeon lsp`
	 * does with its SDK's; without it, `stdlib` in the working directory.
	 */
	public static function run(arguments:Array<String>):Int {
		var stdlib = "stdlib";
		for (argument in arguments)
			if (StringTools.startsWith(argument, "--stdlib=") && argument.length > "--stdlib=".length)
				stdlib = argument.substr("--stdlib=".length);
			else
				throw new InternalError('Unexpected lsp argument "$argument"');
		if (Sys.systemName() == "Windows")
			binaryStdio();
		var protocol = new LspProtocol(new compiler.service.LanguageService(null, stdlib)),
			input = Sys.stdin(),
			output = Sys.stdout(),
			outputMutex = new sys.thread.Mutex(),
			dispatcher = new LspDispatcher(protocol, response -> {
				var bytes = Bytes.ofString(escapeControlCharacters(response));
				outputMutex.acquire();
				output.writeString('Content-Length: ${bytes.length}\r\n\r\n');
				output.write(bytes);
				output.flush();
				outputMutex.release();
			});
		while (true) {
			var contentLength = -1;
			try {
				while (true) {
					var header = input.readLine();
					if (header.length == 0)
						break;
					if (StringTools.startsWith(header.toLowerCase(), "content-length:"))
						contentLength = Std.parseInt(StringTools.trim(header.substr(15)));
				}
			} catch (_:Eof) {
				break;
			}
			if (contentLength < 0)
				continue;
			var message = input.readString(contentLength);
			if (dispatcher.dispatch(message))
				break;
		}
		dispatcher.finish();
		return 0;
	}

	/** Upstream Haxe's JSON printer leaves C0 controls raw; JSON strings require them escaped. */
	static function escapeControlCharacters(json:String):String {
		var escaped:Null<StringBuf> = null, start = 0;
		for (index in 0...json.length) {
			var code = StringTools.fastCodeAt(json, index);
			if (code >= 0x20)
				continue;
			if (escaped == null)
				escaped = new StringBuf();
			escaped.addSub(json, start, index - start);
			escaped.add("\\u00" + StringTools.hex(code, 2));
			start = index + 1;
		}
		if (escaped == null)
			return json;
		escaped.addSub(json, start);
		return escaped.toString();
	}

	#if (hl && !haxeon)
	@:hlNative("haxeon_runtime", "__sys_binary_stdio")
	static function binaryStdio():Void {}
	#else
	static function binaryStdio():Void {}
	#end
}
