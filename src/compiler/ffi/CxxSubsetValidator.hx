package compiler.ffi;

import compiler.Source.SourceSpan;
import compiler.ffi.CxxModel.CxxFunction;
import compiler.ffi.CxxModel.CxxEnum;
import compiler.ffi.CxxModel.CxxAlias;
import compiler.ffi.CxxModel.CxxMethod;
import compiler.ffi.CxxModel.CxxModel;
import compiler.ffi.CxxModel.CxxRecord;
import compiler.ffi.CxxModel.CxxType;

typedef CxxDiagnostic = {
	final code:String;
	final message:String;
	final span:SourceSpan;
}

/** Enforces the intentionally small, direct-call CXX_ABI_V1 profile. */
class CxxSubsetValidator {
	public static inline final PROFILE = "CXX_ABI_V1";

	public static function validate(model:CxxModel, trivialValues:Bool = false, lifetimes:Bool = false, virtualDispatch:Bool = false, cxxThunks:Bool = false,
			?cxxOwnership:Map<String, String>):Array<CxxDiagnostic> {
		var diagnostics:Array<CxxDiagnostic> = [],
			records:Map<String, CxxRecord> = [],
			enums:Map<String, CxxEnum> = [],
			aliases:Map<String, CxxAlias> = [];
		validateTarget(model, diagnostics);
		for (record in model.records)
			records.set(record.qualifiedName, record);
		for (enumModel in model.enums)
			enums.set(enumModel.qualifiedName, enumModel);
		for (alias in model.aliases)
			aliases.set(alias.qualifiedName, alias);
		for (record in model.records) {
			if (record.bases.length > 0
				&& (!virtualDispatch || record.bases.length > 1 || Lambda.exists(record.bases, base -> base.isVirtual)))
				diagnostics.push({code: "CXX005", message: 'inheritance for ${record.qualifiedName} is unsupported by CXX_ABI_V1', span: record.span});
			for (method in record.methods)
				validateMethod(method, record, records, enums, aliases, diagnostics, trivialValues, lifetimes, virtualDispatch, cxxThunks);
		}
		for (functionModel in model.functions) {
			if (functionModel.symbol.length == 0)
				diagnostics.push({
					code: "CXX011",
					message: 'Clang did not provide a mangled symbol for ${functionModel.qualifiedName}',
					span: functionModel.span
				});
			if (!functionModel.isNoexcept && !cxxThunks)
				diagnostics.push({
					code: "CXX003",
					message: '${functionModel.qualifiedName} may throw; direct C++ calls require noexcept',
					span: functionModel.span
				});
			validateResultType(functionModel.result, functionModel.span, diagnostics, cxxThunks);
			validateType(functionModel.result, true, functionModel.span, records, enums, aliases, diagnostics, trivialValues, cxxThunks);
			for (parameter in functionModel.parameters)
				validateType(parameter.type, true, parameter.span, records, enums, aliases, diagnostics, trivialValues, cxxThunks);
		}
		for (alias in model.aliases)
			validateType(alias.target, true, alias.span, records, enums, aliases, diagnostics, trivialValues, cxxThunks);
		if (cxxOwnership != null)
			validateOwnership(model, cxxOwnership, diagnostics, cxxThunks);
		return diagnostics;
	}

	static function validateTarget(model:CxxModel, diagnostics:Array<CxxDiagnostic>):Void {
		var target = model.target.toLowerCase(),
			architecture = target.split("-")[0],
			supportedArchitecture = architecture == "x86_64" || architecture == "amd64" || architecture == "aarch64" || architecture == "arm64",
			supportedPlatform = target.indexOf("linux") >= 0 || target.indexOf("darwin") >= 0 || target.indexOf("apple") >= 0
				|| target.indexOf("windows") >= 0 || target.indexOf("msvc") >= 0 || target.indexOf("mingw") >= 0;
		if (!supportedArchitecture || !supportedPlatform)
			diagnostics.push({
				code: "CXX013",
				message: 'target "$target" is outside $PROFILE (supported: x86_64/aarch64 Linux, macOS, and x64 Windows)',
				span: model.span
			});
	}

	public static function throwIfInvalid(model:CxxModel, trivialValues:Bool = false, lifetimes:Bool = false, virtualDispatch:Bool = false,
			cxxThunks:Bool = false, ?cxxOwnership:Map<String, String>):Void {
		var diagnostics = validate(model, trivialValues, lifetimes, virtualDispatch, cxxThunks, cxxOwnership);
		if (diagnostics.length == 0)
			return;
		var lines = [
			for (diagnostic in diagnostics) {
				var position = diagnostic.span.file.lineColumnAt(diagnostic.span.start);
				'${diagnostic.code} ${diagnostic.span.file.path}:${position.line}:${position.column}: ${diagnostic.message}';
			}
		];
		throw lines.join("\n");
	}

	static function validateOwnership(model:CxxModel, ownership:Map<String, String>, diagnostics:Array<CxxDiagnostic>, cxxThunks:Bool):Void {
		var functions:Map<String, CxxFunction> = [];
		for (functionModel in model.functions)
			functions.set(functionModel.qualifiedName, functionModel);
		for (ownerName => releaseName in ownership) {
			var owner = functions.get(ownerName),
				release = functions.get(releaseName);
			if (owner == null) {
				diagnostics.push({code: "CXX020", message: 'owned C++ result "$ownerName" must name a free function in the imported header', span: model.span});
				continue;
			}
			if (release == null) {
				diagnostics.push({
					code: "CXX020",
					message: 'owned C++ result "$ownerName" refers to missing release function "$releaseName"',
					span: owner.span
				});
				continue;
			}
			var ownerType = pointerRecord(owner.result);
			if (ownerType == null) {
				diagnostics.push({code: "CXX020", message: 'owned C++ result "$ownerName" must return a pointer to an imported record', span: owner.span});
				continue;
			}
			if (!release.isNoexcept && !cxxThunks)
				diagnostics.push({code: "CXX020", message: 'release function "$releaseName" must be noexcept or use generated C++ thunks', span: release.span});
			var releaseType = release.parameters.length == 1 ? pointerRecord(release.parameters[0].type) : null,
				releaseIsVoid = release.parameters.length == 1 && isVoidPointer(release.parameters[0].type);
			if (release.parameters.length != 1 || (releaseType != ownerType && !releaseIsVoid) || !isVoid(release.result))
				diagnostics.push({
					code: "CXX020",
					message: 'release function "$releaseName" must accept one pointer to "$ownerType" (or void*) and return void',
					span: release.span
				});
		}
	}

	static function pointerRecord(type:CxxType):Null<String>
		return switch type {
			case CxxType.CxxPointer(element): namedRecord(element);
			case CxxType.CxxConst(element): pointerRecord(element);
			case _: null;
		};

	static function namedRecord(type:CxxType):Null<String>
		return switch type {
			case CxxType.CxxNamed(name): name;
			case CxxType.CxxConst(element): namedRecord(element);
			case _: null;
		};

	static function isVoidPointer(type:CxxType):Bool
		return switch type {
			case CxxType.CxxPointer(element): isVoid(element);
			case CxxType.CxxConst(element): isVoidPointer(element);
			case _: false;
		};

	static function isVoid(type:CxxType):Bool
		return switch type {
			case CxxType.CxxPrimitive("void") | CxxType.CxxVoid: true;
			case CxxType.CxxConst(element): isVoid(element);
			case _: false;
		};

	static function validateMethod(method:CxxMethod, record:CxxRecord, records:Map<String, CxxRecord>, enums:Map<String, CxxEnum>,
			aliases:Map<String, CxxAlias>, diagnostics:Array<CxxDiagnostic>, trivialValues:Bool, lifetimes:Bool, virtualDispatch:Bool, cxxThunks:Bool):Void {
		if ((method.isConstructor || method.isDestructor) && !lifetimes)
			diagnostics.push({
				code: "CXX008",
				message: 'constructors and destructors are disabled; pass --cxx-lifetimes to enable ${method.qualifiedName}',
				span: method.span
			});
		if ((method.isConstructor || method.isDestructor) && lifetimes) {
			if (!record.completeDefinition || record.size <= 0 || record.align <= 0)
				diagnostics.push({
					code: "CXX014",
					message: 'lifetime operation ${method.qualifiedName} requires a complete record with a usable size and alignment',
					span: record.span
				});
			if (record.align > 16)
				diagnostics.push({
					code: "CXX014",
					message: 'lifetime operation ${method.qualifiedName} requires alignment ${record.align}, above the 16-byte native allocation guarantee',
					span: record.span
				});
			if (method.isConstructor) {
				var hasExplicitDestructor = false;
				for (candidate in record.methods)
					if (candidate.isDestructor)
						hasExplicitDestructor = true;
				if (!hasExplicitDestructor)
					diagnostics.push({
						code: "CXX014",
						message: 'constructor ${method.qualifiedName} requires an explicit noexcept destructor for owned projection',
						span: method.span
					});
			}
		}
		if ((method.isConstructor || method.isDestructor)
			&& CxxTypeTools.hasStringView([for (parameter in method.parameters) parameter.type]))
			diagnostics.push({
				code: "CXX017",
				message: 'std::string_view adapters are unsupported for constructors and destructors (${method.qualifiedName})',
				span: method.span
			});
		if ((method.isConstructor || method.isDestructor)
			&& CxxTypeTools.hasByteSpan([for (parameter in method.parameters) parameter.type]))
			diagnostics.push({
				code: "CXX018",
				message: 'std::span byte adapters are unsupported for constructors and destructors (${method.qualifiedName})',
				span: method.span
			});
		if (method.symbol.length == 0)
			diagnostics.push({code: "CXX011", message: 'Clang did not provide a mangled symbol for ${method.qualifiedName}', span: method.span});
		if (!method.isNoexcept && !cxxThunks)
			diagnostics.push({code: "CXX003", message: '${method.qualifiedName} may throw; direct C++ calls require noexcept', span: method.span});
		else if (!method.isNoexcept && (method.isConstructor || method.isDestructor))
			diagnostics.push({
				code: "CXX016",
				message: 'generated C++ thunks do not support throwing constructors or destructors (${method.qualifiedName})',
				span: method.span
			});
		if (method.isVirtual) {
			if (!virtualDispatch)
				diagnostics.push({
					code: "CXX004",
					message: 'virtual member ${method.qualifiedName} requires virtual dispatch; pass --cxx-virtual to enable Itanium single-inheritance dispatch',
					span: method.span
				});
			else if (!method.isConstructor && !method.isDestructor && method.virtualAbi == null)
				diagnostics.push({
					code: "CXX015",
					message: 'virtual member ${method.qualifiedName} has no Clang vtable index for the selected Itanium target',
					span: method.span
				});
			else if (method.isConstructor || method.isDestructor)
				diagnostics.push({
					code: "CXX015",
					message: 'virtual constructors and destructors are not supported by Itanium vtable dispatch',
					span: method.span
				});
		}
		if (method.access != "public")
			diagnostics.push({code: "CXX010", message: 'member ${method.qualifiedName} is ${method.access} and cannot be projected', span: method.span});
		if (StringTools.startsWith(method.name, "operator"))
			diagnostics.push({code: "CXX009", message: 'member-function operator ${method.qualifiedName} is unsupported', span: method.span});
		validateResultType(method.result, method.span, diagnostics, cxxThunks);
		validateType(method.result, true, method.span, records, enums, aliases, diagnostics, trivialValues, cxxThunks);
		for (parameter in method.parameters)
			validateType(parameter.type, true, parameter.span, records, enums, aliases, diagnostics, trivialValues, cxxThunks);
	}

	static function validateType(type:CxxType, byValue:Bool, span:SourceSpan, records:Map<String, CxxRecord>, enums:Map<String, CxxEnum>,
			aliases:Map<String, CxxAlias>, diagnostics:Array<CxxDiagnostic>, trivialValues:Bool, cxxThunks:Bool):Void {
		switch type {
			case CxxType.CxxVoid | CxxType.CxxPrimitive(_):
			case CxxType.CxxConst(element):
				validateType(element, byValue, span, records, enums, aliases, diagnostics, trivialValues, cxxThunks);
			case CxxType.CxxPointer(element) | CxxType.CxxReference(element):
				validateType(element, false, span, records, enums, aliases, diagnostics, trivialValues, cxxThunks);
			case CxxType.CxxFunctionPointer(parameters, result, _):
				if (isFunctionPointer(result))
					diagnostics.push({code: "CXX021", message: "nested function-pointer callback results are unsupported", span: span});
				validateCallbackResult(result, span, records, enums, aliases, diagnostics, trivialValues, cxxThunks);
				for (parameter in parameters) {
					if (isFunctionPointer(parameter))
						diagnostics.push({code: "CXX021", message: "nested function-pointer callback parameters are unsupported", span: span});
					validateType(parameter, false, span, records, enums, aliases, diagnostics, trivialValues, cxxThunks);
				}
			case CxxType.CxxRValueReference(_):
				diagnostics.push({code: "CXX001", message: "rvalue references are unsupported by CXX_ABI_V1", span: span});
			case CxxType.CxxStringView:
				if (!cxxThunks)
					diagnostics.push({
						code: "CXX017",
						message: 'std::string_view requires a generated C++ adapter; pass --cxx-thunks=<file>',
						span: span
					});
				else if (!byValue)
					diagnostics.push({
						code: "CXX017",
						message: "std::string_view is supported only as a by-value input parameter",
						span: span
					});
			case CxxType.CxxByteSpan(_):
				if (!cxxThunks)
					diagnostics.push({
						code: "CXX018",
						message: 'std::span byte adapters require a generated C++ adapter; pass --cxx-thunks=<file>',
						span: span
					});
				else if (!byValue)
					diagnostics.push({
						code: "CXX018",
						message: "std::span byte adapters are supported only as by-value input parameters",
						span: span
					});
			case CxxType.CxxUnsupported(raw, reason):
				diagnostics.push({code: "CXX009", message: 'unsupported C++ type "$raw": $reason', span: span});
			case CxxType.CxxNamed(name):
				var record = records.get(name);
				if (record == null && !enums.exists(name) && !aliases.exists(name))
					diagnostics.push({code: "CXX012", message: 'unknown C++ type "$name"', span: span});
				if (record != null && byValue) {
					if (!trivialValues)
						diagnostics.push({
							code: "CXX002",
							message: 'non-trivial value parameter/result "$name" is disabled; use a pointer or --cxx-trivial-values',
							span: record.span
						});
					else if (!record.isStandardLayout || !record.isTriviallyCopyable || record.bases.length != 0 || record.hasVirtualMembers)
						diagnostics.push({code: "CXX002", message: 'record "$name" is not a validated trivial C++ value', span: record.span});
				}
		}
	}

	static function validateResultType(type:CxxType, span:SourceSpan, diagnostics:Array<CxxDiagnostic>, cxxThunks:Bool):Void {
		if (cxxThunks && CxxTypeTools.isStringView(type))
			diagnostics.push({
				code: "CXX017",
				message: "std::string_view results are unsupported; return an owning std::string or a pointer/length pair",
				span: span
			});
		if (cxxThunks && CxxTypeTools.isByteSpan(type))
			diagnostics.push({
				code: "CXX018",
				message: "std::span byte results are unsupported; return an owning byte container or a pointer/length pair",
				span: span
			});
		if (isFunctionPointer(type))
			diagnostics.push({
				code: "CXX021",
				message: "function-pointer results are unsupported; pass callbacks as input parameters",
				span: span
			});
	}

	static function validateCallbackResult(type:CxxType, span:SourceSpan, records:Map<String, CxxRecord>, enums:Map<String, CxxEnum>,
			aliases:Map<String, CxxAlias>, diagnostics:Array<CxxDiagnostic>, trivialValues:Bool, cxxThunks:Bool):Void {
		switch type {
			case CxxType.CxxPointer(_) | CxxType.CxxReference(_) | CxxType.CxxRValueReference(_) | CxxType.CxxStringView | CxxType.CxxByteSpan(_):
				diagnostics.push({code: "CXX021", message: "callback results must be scalar, enum, validated aggregate, or void", span: span});
			case CxxType.CxxFunctionPointer(_, _, _):
				diagnostics.push({code: "CXX021", message: "nested function-pointer callback results are unsupported", span: span});
			case _:
				validateType(type, true, span, records, enums, aliases, diagnostics, trivialValues, cxxThunks);
		}
	}

	static function isFunctionPointer(type:CxxType):Bool
		return switch type {
			case CxxType.CxxFunctionPointer(_, _, _): true;
			case CxxType.CxxConst(element): isFunctionPointer(element);
			case _: false;
		};
}
