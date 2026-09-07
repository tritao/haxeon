package editor;

import compiler.Diagnostic.CompileError;
import compiler.service.LanguageService;
import compiler.service.CancellationToken;
import compiler.service.CancellationError;
import compiler.service.LanguageService.DocumentSymbol;
import compiler.service.LanguageService.SymbolLocation;
import compiler.service.LanguageService.TextEdit;
import compiler.hl.HlWriter;
import compiler.abi.AbiChangeSchema;
import compiler.compilation.CompilerPublication.ReconnectDecision;
import compiler.compilation.CompilerPublication.ReconnectReason;
import haxe.crypto.Base64;
import haxe.Json;
import sys.thread.Mutex;

/** JSON-lines adapter for the persistent compiler service.

	The compiler remains the owner of parsing, typing, diagnostics, and symbols;
	this class only translates editor messages to the existing service API.
 */
class LanguageServiceProtocol {
	final service:LanguageService;
	final activeRequests:Map<String, CancellationToken> = [];
	final activeRequestsMutex = new Mutex();
	final serviceMutex = new Mutex();

	public function new(?service:LanguageService) {
		this.service = service == null ? new LanguageService() : service;
		this.service.compiler.enablePublicationTracking();
	}

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
		activeRequestsMutex.acquire();
		if (activeRequests.exists(requestKey)) {
			activeRequestsMutex.release();
			return failure(id, "E_DUPLICATE_REQUEST", "Request id is already active");
		}
		activeRequests.set(requestKey, token);
		activeRequestsMutex.release();
		serviceMutex.acquire();
		try {
			token.check();
			var result:Dynamic;
			switch method {
				case "update":
					service.update(requiredString(request, "path"), requiredString(request, "source"));
					result = cast {updated: true};
				case "compile":
					var build = service.compile(requiredString(request, "entry"), token);
					var initialLoad = build.revision == 1 && !build.requiresReload && build.patchBytes == null,
						artifactKind = build.patchBytes != null ? "patch" : build.requiresReload || initialLoad ? "module" : "none";
					result = cast {
						compatibility: {
							schemaVersion: AbiChangeSchema.VERSION,
							decision: build.requiresReload ? "reload_domain" : initialLoad ? "initial_load" : "patch",
							baseRevision: artifactKind == "patch" ? build.revision - 1 : 0,
							targetRevision: build.revision,
							domainIdentity: Base64.encode(build.runtimeIdentity.sub(4, 16)),
							artifactKind: artifactKind,
							reasons: [for (reason in build.reloadReasons) AbiChangeSchema.encode(reason)]
						},
						revision: build.revision,
						retyped: build.retyped,
						regenerated: build.regenerated,
						changedFunctions: build.changedFunctions,
						requiresReload: build.requiresReload,
						patchAvailable: build.patchBytes != null,
						moduleBase64: Base64.encode(HlWriter.encode(build.module)),
						patchBase64: build.patchBytes == null ? null : Base64.encode(build.patchBytes),
						runtimeIdentityBase64: Base64.encode(build.runtimeIdentity),
						metrics: build.metrics
					};
				case "acknowledge":
					service.compiler.acknowledgePublication(requiredInt(request, "revision"));
					result = cast publicationJson();
				case "reject":
					service.compiler.rejectPublication(requiredInt(request, "revision"));
					result = cast publicationJson();
				case "reconnect":
					var identity = Base64.decode(requiredString(request, "domainIdentity"));
					result = cast reconnectJson(service.compiler.reconcileRuntime(identity, requiredInt(request, "revision")));
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
						for (item in service.complete(requiredString(request, "path"), requiredInt(request, "position"), token))
							cast item
					];
				case "hover":
					result = service.hover(requiredString(request, "path"), requiredInt(request, "position"));
				case "definition":
					result = cast locationJson(service.definition(requiredString(request, "path"), requiredInt(request, "position")));
				case "references":
					result = cast [
						for (location in service.references(requiredString(request, "path"), requiredInt(request, "position"), token))
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
			finishRequest(requestKey);
			return Json.stringify({id: id, ok: true, result: result});
		} catch (error:CancellationError) {
			finishRequest(requestKey);
			return failure(id, "E_CANCELLED", "Request cancelled");
		} catch (error:CompileError) {
			finishRequest(requestKey);
			return failureDiagnostic(id, error.diagnostic);
		} catch (error:Dynamic) {
			finishRequest(requestKey);
			return failure(id, "E0000", Std.string(error));
		}
	}

	function finishRequest(requestKey:String):Void {
		serviceMutex.release();
		activeRequestsMutex.acquire();
		activeRequests.remove(requestKey);
		activeRequestsMutex.release();
	}

	/** Cancel a currently running request by its JSON id. */
	public function cancel(requestId:Dynamic):Bool {
		activeRequestsMutex.acquire();
		var request = activeRequests.get(key(requestId));
		if (request == null) {
			activeRequestsMutex.release();
			return false;
		}
		request.cancel();
		activeRequestsMutex.release();
		return true;
	}

	static function key(value:Dynamic):String
		return value == null ? "null" : Std.isOfType(value, String) ? "string:" + cast(value, String) : "value:" + Json.stringify(value);

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

	function publicationJson():Dynamic {
		var status = service.compiler.publicationStatus();
		return {
			acknowledgedRevision: status.acknowledgedRevision,
			hasPendingRevision: status.hasPendingRevision,
			pendingRevision: status.pendingRevision
		};
	}

	static function reconnectJson(decision:ReconnectDecision):Dynamic
		return switch decision {
			case ContinuePatching: {decision: "continue_patching", reason: null};
			case ReloadDomain(reason): {decision: "reload_domain", reason: reconnectReasonJson(reason)};
		};

	static function reconnectReasonJson(reason:ReconnectReason):Dynamic
		return switch reason {
			case PublicationTrackingDisabled: {code: "publication_tracking_disabled"};
			case PublicationPending(revision): {code: "publication_pending", revision: revision};
			case RuntimeRevisionMismatch(runtimeRevision, acknowledgedRevision): {
					code: "runtime_revision_mismatch",
					runtimeRevision: runtimeRevision,
					acknowledgedRevision: acknowledgedRevision
				};
			case BackendBaselineUnavailable: {code: "backend_baseline_unavailable"};
			case ModuleIdentityMismatch: {code: "module_identity_mismatch"};
		};

	static function failureDiagnostic(id:Dynamic, diagnostic:compiler.Diagnostic):String
		return Json.stringify({id: id, ok: false, error: diagnosticJson(diagnostic)});

	static function failure(id:Dynamic, code:String, message:String):String
		return Json.stringify({id: id, ok: false, error: {code: code, message: message}});
}
