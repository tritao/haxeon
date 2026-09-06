import editor.LspProtocol;
import haxe.io.Bytes;
import haxe.io.Eof;

/** Standard Language Server Protocol entry point over stdio. */
class LspMain {
	static function main():Void {
		var protocol = new LspProtocol(),
			input = Sys.stdin(),
			output = Sys.stdout();
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
			for (response in protocol.handle(message)) {
				var bytes = Bytes.ofString(response);
				output.writeString('Content-Length: ${bytes.length}\r\n\r\n');
				output.write(bytes);
				output.flush();
			}
			if (protocol.shouldExit())
				break;
		}
	}
}
