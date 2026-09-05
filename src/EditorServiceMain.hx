import editor.LanguageServiceProtocol;
import haxe.io.Eof;

/** Standalone JSON-lines entry point for a Pragtical host process. */
class EditorServiceMain {
	static function main():Void {
		var protocol = new LanguageServiceProtocol();
		while (true) {
			var line:String;
			try {
				line = Sys.stdin().readLine();
			} catch (error:Eof) {
				break;
			}
			Sys.println(protocol.handle(line));
			Sys.stdout().flush();
		}
	}
}
