package editor;

import compiler.Diagnostic.CompileError;
import compiler.service.LanguageService;
import compiler.service.CancellationToken;
import compiler.service.CancellationError;
import compiler.service.LanguageService.DocumentSymbol;
import compiler.service.LanguageService.SymbolLocation;
import compiler.service.LanguageService.TextEdit;
import compiler.hl.HlWriter;
import haxe.crypto.Base64;
import haxe.Json;

/** JSON-lines adapter for the persistent compiler service.

	The compiler remains the owner of parsing, typing, diagnostics, and symbols;
	this class only translates editor messages to the existing service API.
 */
class LanguageServiceProtocol {
	final service:LanguageService;
	final activeRequests:Map<String, CancellationToken> = [];

	public function new(?service:LanguageService)
		this.service = service == null ? new LanguageService() : service;

	public function handle(line:String):String
		return handleWithToken(line, new CancellationToken());

	/** Handle a request with a caller-owned token, suitable for a worker thread. */
	public function handleWithToken(line:String, token:CancellationToken):String {
		var request:Dynamic;
		try {
			request = Json.parse(line);
		} catch (error:Dynamic)
			return failure(null, "E0000", "Invalid JSON request");
		var id:Dynamic = Reflect.field(request, "id"),
			method:String = Reflect.field(request, "method");
		if (method == null)
			return failure(id, "E0000", "Request method is required");
		if (method == "cancel") {
			var target = Reflect.field(request, "requestId"),
				cancelled = cancel(target);
			return Json.stringify({id: id, ok: true, result: {cancelled: cancelled}});
		}
		var requestKey = key(id);
		activeRequests.set(requestKey, token);
		try {
			token.check();
			var result:Dynamic;
			switch method {
				case "update":
					service.update(requiredString(request, "path"), requiredString(request, "source"));
					result = cast {updated: true};
				case "compile":
					var build = service.compile(requiredString(request, "entry"), token);
					result = cast {
						revision: build.revision,
						retyped: build.retyped,
						regenerated: build.regenerated,
						changedFunctions: build.changedFunctions,
						requiresReload: build.requiresReload,
						reloadReasons: [for (reason in build.reloadReasons) Std.string(reason)],
						patchAvailable: build.patchBytes != null,
						moduleBase64: Base64.encode(HlWriter.encode(build.module)),
						patchBase64: build.patchBytes == null ? null : Base64.encode(build.patchBytes),
						runtimeIdentityBase64: Base64.encode(build.runtimeIdentity),
						metrics: build.metrics
					};
				case "validate":
					var validation = service.validate(requiredString(request, "path"), requiredString(request, "source"), requiredString(request, "entry"),
						token);
					result = cast {
						valid: validation.valid,
						diagnostic: validation.diagnostic == null ? null : diagnosticJson(validation.diagnostic)
					};
				case "diagnostics":
					result = cast [
						for (diagnostic in service.diagnostics(requiredString(request, "path")))
							cast diagnosticJson(diagnostic)
					];
				case "symbols":
					result = cast [
						for (symbol in service.documentSymbols(requiredString(request, "path")))
							cast symbolJson(symbol)
					];
				case "complete":
					result = cast [
						for (item in service.complete(requiredString(request, "path"), requiredInt(request, "position")))
							cast item
					];
				case "hover":
					result = service.hover(requiredString(request, "path"), requiredInt(request, "position"));
				case "definition":
					result = cast locationJson(service.definition(requiredString(request, "path"), requiredInt(request, "position")));
				case "references":
					result = cast [
						for (location in service.references(requiredString(request, "path"), requiredInt(request, "position")))
							cast locationJson(location)
					];
				case "rename":
					result = cast [
						for (edit in service.rename(requiredString(request, "path"), requiredInt(request, "position"), requiredString(request, "replacement")))
							cast {
								text: edit.path,
								start: edit.span.start,
								end: edit.span.end,
								replacement: edit.replacement
							}
					];
				default:
					throw 'Unknown language-service method "$method"';
			}
			token.check();
			activeRequests.remove(requestKey);
			return Json.stringify({id: id, ok: true, result: result});
		} catch (error:CancellationError) {
			activeRequests.remove(requestKey);
			return failure(id, "E_CANCELLED", "Request cancelled");
		} catch (error:CompileError) {
			activeRequests.remove(requestKey);
			return failureDiagnostic(id, error.diagnostic);
		} catch (error:Dynamic) {
			activeRequests.remove(requestKey);
			return failure(id, "E0000", Std.string(error));
		}
	}

	/** Cancel a currently running request by its JSON id. */
	public function cancel(requestId:Dynamic):Bool {
		var request = activeRequests.get(key(requestId));
		if (request == null)
			return false;
		request.cancel();
		return true;
	}

	static function key(value:Dynamic):String
		return value == null ? "null" : Std.string(value);

	static function requiredString(request:Dynamic, name:String):String {
		var value:Dynamic = Reflect.field(request, name);
		if (value == null || !Std.isOfType(value, String))
			throw 'Request field "$name" must be a string';
		return cast value;
	}

	static function requiredInt(request:Dynamic, name:String):Int {
		var value:Dynamic = Reflect.field(request, name);
		if (value == null || !Std.isOfType(value, Int))
			throw 'Request field "$name" must be an integer';
		return cast value;
	}

	static function diagnosticJson(diagnostic:compiler.Diagnostic):Dynamic
		return {
			code: diagnostic.code,
			message: diagnostic.message,
			severity: Std.string(diagnostic.severity),
			path: diagnostic.span.file.path,
			start: diagnostic.span.start,
			end: diagnostic.span.end
		};

	static function symbolJson(symbol:DocumentSymbol):Dynamic
		return {
			name: symbol.name,
			kind: symbol.kind,
			detail: symbol.detail,
			path: symbol.span.file.path,
			start: symbol.span.start,
			end: symbol.span.end
		};

	static function locationJson(location:Null<SymbolLocation>):Dynamic
		return location == null ? null : {path: location.path, start: location.span.start, end: location.span.end};

	static function failureDiagnostic(id:Dynamic, diagnostic):String
		return Json.stringify({id: id, ok: false, error: diagnosticJson(diagnostic)});

	static function failure(id:Dynamic, code:String, message:String):String
		return Json.stringify({id: id, ok: false, error: {code: code, message: message}});
}
