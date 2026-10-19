import editor.lsp.LspDispatcher;
import editor.lsp.LspProtocol;
import haxe.io.Bytes;
import haxe.io.Eof;
import haxe.io.Path;
import sys.FileSystem;

/** Standard Language Server Protocol entry point over stdio. */
class LspMain {
	static function main():Void {
		useCompilerRoot();
		if (Sys.systemName() == "Windows")
			binaryStdio();
		var protocol = new LspProtocol(),
			input = Sys.stdin(),
			output = Sys.stdout(),
			outputMutex = new sys.thread.Mutex(),
			dispatcher = new LspDispatcher(protocol, response -> {
				var bytes = Bytes.ofString(response);
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
	}

	/** Compiler services resolve `stdlib` from the Haxeon root, which launchers need not select. */
	static function useCompilerRoot():Void {
		if (FileSystem.exists("stdlib"))
			return;
		var root = Sys.getEnv("HAXEON_ROOT");
		if (root == null || root.length == 0)
			root = Path.directory(Path.directory(FileSystem.absolutePath(Sys.programPath())));
		if (FileSystem.exists(Path.join([root, "stdlib"])))
			Sys.setCwd(root);
	}

	#if (hl && !haxeon)
	@:hlNative("haxeon_runtime", "__sys_binary_stdio")
	static function binaryStdio():Void {}
	#else
	static function binaryStdio():Void {}
	#end
}
