import editor.LspDispatcher;
import editor.LspProtocol;
import haxe.io.Bytes;
import haxe.io.Eof;

/** Standard Language Server Protocol entry point over stdio. */
class LspMain {
	static function main():Void {
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
}
