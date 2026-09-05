import editor.LanguageServiceProtocol;
import compiler.service.CancellationToken;
import haxe.Json;

class ProtocolMain {
	static function main():Void {
		var protocol = new LanguageServiceProtocol();
		assertOk(protocol.handle('{"id":1,"method":"update","path":"Main.hx","source":"class Editor { public var active:Int; public function new() { } } function main():Int { var editor = new Editor(); editor.active; return 42; }"}'));
		var compiled:Dynamic = Json.parse(protocol.handle('{"id":2,"method":"compile","entry":"Main"}'));
		if (!compiled.ok
			|| compiled.result.revision != 1
			|| compiled.result.requiresReload
			|| compiled.result.compatibility.schemaVersion != 1
			|| compiled.result.compatibility.decision != "initial_load"
			|| compiled.result.compatibility.baseRevision != 0
			|| compiled.result.compatibility.targetRevision != 1
			|| compiled.result.compatibility.artifactKind != "module"
			|| compiled.result.compatibility.domainIdentity == null
			|| compiled.result.compatibility.reasons.length != 0
			|| compiled.result.moduleBase64 == null
			|| compiled.result.moduleBase64.length == 0
			|| compiled.result.runtimeIdentityBase64 == null
			|| compiled.result.runtimeIdentityBase64.length == 0
			|| compiled.result.metrics == null
			|| compiled.result.patchBase64 != null)
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
		var validation:Dynamic = Json.parse(protocol.handle('{"id":4,"method":"validate","path":"Main.hx","entry":"Main","source":'
			+ Json.stringify(source)
			+ '}'));
		if (!validation.ok || !validation.result.valid || validation.result.diagnostic != null)
			throw "protocol validation did not accept a valid snapshot";
		var invalidValidation:Dynamic = Json.parse(protocol.handle('{"id":5,"method":"validate","path":"Main.hx","entry":"Main","source":'
			+ Json.stringify("function main(:Int { return 0; }")
			+ '}'));
		if (!invalidValidation.ok || invalidValidation.result.valid || invalidValidation.result.diagnostic == null)
			throw "protocol validation did not return an edit diagnostic";
		var diagnostics:Dynamic = Json.parse(protocol.handle('{"id":6,"method":"diagnostics","path":"Main.hx"}'));
		if (!diagnostics.ok || diagnostics.result.length != 0)
			throw "protocol diagnostics response was not empty";
		var editedSource = StringTools.replace(source, "return 42", "return 41");
		assertOk(protocol.handle('{"id":7,"method":"update","path":"Main.hx","source":' + Json.stringify(editedSource) + '}'));
		var patched:Dynamic = Json.parse(protocol.handle('{"id":8,"method":"compile","entry":"Main"}'));
		if (!patched.ok
			|| patched.result.requiresReload
			|| !patched.result.patchAvailable
			|| patched.result.patchBase64 == null
			|| patched.result.patchBase64.length == 0
			|| patched.result.compatibility.decision != "patch"
			|| patched.result.compatibility.baseRevision != 1
			|| patched.result.compatibility.targetRevision != 2
			|| patched.result.compatibility.artifactKind != "patch")
			throw "protocol compile did not transport a compatible patch";
		var structuralSource = StringTools.replace(editedSource, "public var active:Int;", "public var active:Int; public var generation:Int;");
		assertOk(protocol.handle('{"id":81,"method":"update","path":"Main.hx","source":' + Json.stringify(structuralSource) + '}'));
		var reload:Dynamic = Json.parse(protocol.handle('{"id":82,"method":"compile","entry":"Main"}'));
		if (!reload.ok
			|| reload.result.compatibility.decision != "reload_domain"
			|| reload.result.compatibility.artifactKind != "module"
			|| reload.result.compatibility.reasons.length == 0
			|| reload.result.compatibility.reasons[0].code != "object_layout_changed"
			|| reload.result.compatibility.reasons[0].entityKind != "object"
			|| reload.result.compatibility.reasons[0].entityId != "Editor")
			throw "protocol compile did not return a structured reload decision";
		var invalid:Dynamic = Json.parse(protocol.handle('{"id":9,"method":"update","path":"Main.hx","source":"function main(:Int { return 0; }"}'));
		if (!invalid.ok)
			throw "protocol update should acknowledge unsaved edits";
		var failed:Dynamic = Json.parse(protocol.handle('{"id":10,"method":"compile","entry":"Main"}'));
		if (failed.ok || failed.error.code == null || failed.error.message == null)
			throw "protocol compile did not return a structured diagnostic";
		var malformed:Dynamic = Json.parse(protocol.handle("not-json"));
		if (malformed.ok || malformed.error.code != "E0000")
			throw "protocol malformed request was not rejected";
		var cancelledToken = new CancellationToken();
		cancelledToken.cancel();
		var cancelled:Dynamic = Json.parse(protocol.handleWithToken('{"id":11,"method":"symbols","path":"Main.hx"}', cancelledToken));
		if (cancelled.ok || cancelled.error.code != "E_CANCELLED")
			throw "protocol cancellation token was not propagated";
		var unknownCancel:Dynamic = Json.parse(protocol.handle('{"id":12,"method":"cancel","requestId":"missing"}'));
		if (!unknownCancel.ok || unknownCancel.result.cancelled)
			throw "protocol cancelled an unknown request";
		Sys.println("PASS: language-service JSON protocol is transactional");
	}

	static function assertOk(response:String):Void {
		var parsed:Dynamic = Json.parse(response);
		if (!parsed.ok)
			throw 'protocol request failed: ${parsed.error.message}';
	}
}
