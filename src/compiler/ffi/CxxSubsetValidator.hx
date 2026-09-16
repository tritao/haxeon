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

	public static function validate(model:CxxModel, trivialValues:Bool = false, lifetimes:Bool = false, virtualDispatch:Bool = false):Array<CxxDiagnostic> {
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
				validateMethod(method, record, records, enums, aliases, diagnostics, trivialValues, lifetimes, virtualDispatch);
		}
		for (functionModel in model.functions) {
			if (functionModel.symbol.length == 0)
				diagnostics.push({
					code: "CXX011",
					message: 'Clang did not provide a mangled symbol for ${functionModel.qualifiedName}',
					span: functionModel.span
				});
			if (!functionModel.isNoexcept)
				diagnostics.push({
					code: "CXX003",
					message: '${functionModel.qualifiedName} may throw; direct C++ calls require noexcept',
					span: functionModel.span
				});
			validateType(functionModel.result, true, functionModel.span, records, enums, aliases, diagnostics, trivialValues);
			for (parameter in functionModel.parameters)
				validateType(parameter.type, true, parameter.span, records, enums, aliases, diagnostics, trivialValues);
		}
		for (alias in model.aliases)
			validateType(alias.target, true, alias.span, records, enums, aliases, diagnostics, trivialValues);
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

	public static function throwIfInvalid(model:CxxModel, trivialValues:Bool = false, lifetimes:Bool = false, virtualDispatch:Bool = false):Void {
		var diagnostics = validate(model, trivialValues, lifetimes, virtualDispatch);
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

	static function validateMethod(method:CxxMethod, record:CxxRecord, records:Map<String, CxxRecord>, enums:Map<String, CxxEnum>,
			aliases:Map<String, CxxAlias>, diagnostics:Array<CxxDiagnostic>, trivialValues:Bool, lifetimes:Bool, virtualDispatch:Bool):Void {
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
		if (method.symbol.length == 0)
			diagnostics.push({code: "CXX011", message: 'Clang did not provide a mangled symbol for ${method.qualifiedName}', span: method.span});
		if (!method.isNoexcept)
			diagnostics.push({code: "CXX003", message: '${method.qualifiedName} may throw; direct C++ calls require noexcept', span: method.span});
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
		validateType(method.result, true, method.span, records, enums, aliases, diagnostics, trivialValues);
		for (parameter in method.parameters)
			validateType(parameter.type, true, parameter.span, records, enums, aliases, diagnostics, trivialValues);
	}

	static function validateType(type:CxxType, byValue:Bool, span:SourceSpan, records:Map<String, CxxRecord>, enums:Map<String, CxxEnum>,
			aliases:Map<String, CxxAlias>, diagnostics:Array<CxxDiagnostic>, trivialValues:Bool):Void {
		switch type {
			case CxxType.CxxVoid | CxxType.CxxPrimitive(_):
			case CxxType.CxxConst(element):
				validateType(element, byValue, span, records, enums, aliases, diagnostics, trivialValues);
			case CxxType.CxxPointer(element) | CxxType.CxxReference(element):
				validateType(element, false, span, records, enums, aliases, diagnostics, trivialValues);
			case CxxType.CxxRValueReference(_):
				diagnostics.push({code: "CXX001", message: "rvalue references are unsupported by CXX_ABI_V1", span: span});
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
}
