import editor.LanguageServiceProtocol;
import haxe.Json;

class ProtocolMain {
	static function main():Void {
		var protocol = new LanguageServiceProtocol();
		assertOk(protocol.handle('{"id":1,"method":"update","path":"Main.hx","source":"class Editor { public var active:Int; public function new() { } } function main():Int { var editor = new Editor(); editor.active; return 42; }"}'));
		var compiled:Dynamic = Json.parse(protocol.handle('{"id":2,"method":"compile","entry":"Main"}'));
		if (!compiled.ok || compiled.result.revision != 1 || compiled.result.requiresReload)
			throw "protocol compile response was incomplete";
		var source = "class Editor { public var active:Int; public function new() { } } function main():Int { var editor = new Editor(); editor.active; return 42; }",
			completion:Dynamic = Json.parse(protocol.handle('{"id":3,"method":"complete","path":"Main.hx","position":'
				+ (source.indexOf("editor.active") + "editor.".length)
				+ '}'));
		var hasActive = false;
		if (completion.ok) {
			var completionItems:Array<Dynamic> = cast completion.result;
			for (item in completionItems)
				if (item.label == "active" && item.detail == "active:Int")
					hasActive = true;
		}
		if (!hasActive)
			throw "protocol completion response was incomplete";
		var diagnostics:Dynamic = Json.parse(protocol.handle('{"id":4,"method":"diagnostics","path":"Main.hx"}'));
		if (!diagnostics.ok || diagnostics.result.length != 0)
			throw "protocol diagnostics response was not empty";
		var invalid:Dynamic = Json.parse(protocol.handle('{"id":5,"method":"update","path":"Main.hx","source":"function main(:Int { return 0; }"}'));
		if (!invalid.ok)
			throw "protocol update should acknowledge unsaved edits";
		var failed:Dynamic = Json.parse(protocol.handle('{"id":6,"method":"compile","entry":"Main"}'));
		if (failed.ok || failed.error.code == null || failed.error.message == null)
			throw "protocol compile did not return a structured diagnostic";
		var malformed:Dynamic = Json.parse(protocol.handle("not-json"));
		if (malformed.ok || malformed.error.code != "E0000")
			throw "protocol malformed request was not rejected";
		Sys.println("PASS: language-service JSON protocol is transactional");
	}

	static function assertOk(response:String):Void {
		var parsed:Dynamic = Json.parse(response);
		if (!parsed.ok)
			throw 'protocol request failed: ${parsed.error.message}';
	}
}
