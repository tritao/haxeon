package compiler.ffi;

import compiler.Source.SourceSpan;
import compiler.ffi.HxiModel.HxiDeclaration;

/** Declaration provenance travels with each generated module, independent of naming policy. */
class HxiSourceOrigins {
	public static function forModule(plan:HaxeProjectionModel, kind:String):Map<String, SourceSpan> {
		var result:Map<String, SourceSpan> = [], declarations:Map<String, HxiDeclaration> = [];
		for (declaration in plan.source.declarations)
			declarations.set(HxiHaxeEmitter.declarationName(declaration), declaration);
		var profile = plan.profile;
		var splitTypes = profile.typeModule != null && profile.typeModule != profile.functionModule;
		var splitConstants = profile.constantModule != null && profile.constantModule != profile.functionModule;
		var types = kind == "all" || kind == "types" || kind == "functions" && !splitTypes;
		var functions = kind == "all" || kind == "functions";
		var constants = kind == "all" || kind == "constants" || kind == "functions" && !splitConstants;
		if (types) {
			for (handle in plan.handles) {
				var origin = span(declarations.get(handle.nativeName));
				result.set(handle.name, origin);
				if (handle.ownedName != null) result.set(handle.ownedName, origin);
				if (handle.owned != null) result.set(handle.owned.name, origin);
			}
			for (callback in plan.callbacks) {
				var origin = span(declarations.get(callback.nativeName));
				result.set(callback.name, origin);
				result.set(callback.name + "Callback", origin);
			}
			for (enumeration in plan.enums) {
				var declaration = declarations.get(enumeration.nativeName);
				result.set(enumeration.name, span(declaration));
				switch declaration {
					case Enumeration(_, _, _, values, _):
						for (value in enumeration.values)
							for (native in values) if (native.name == value.nativeName)
								result.set(enumeration.name + "." + value.name, native.span);
					case _:
				}
			}
			for (structure in plan.structures) {
				var declaration = declarations.get(structure.nativeName);
				result.set(structure.name, span(declaration));
				switch declaration {
					case Structure(_, _, _, fields, _):
						for (field in structure.fields)
							for (native in fields) if (native.name == field.nativeName) {
								result.set(structure.name + "." + field.name, native.span);
								result.set(structure.name + ".get_" + field.name, native.span);
								result.set(structure.name + ".set_" + field.name, native.span);
							}
					case _:
				}
			}
			if (profile.typeModule != null) result.set(profile.typeModule, plan.source.span);
		}
		if (functions) {
			for (fn in plan.functions) {
				var origin = span(declarations.get(fn.nativeName));
				result.set(fn.name, origin);
				result.set(fn.rawName, origin);
				if (fn.checked != null) result.set(fn.checked.name, origin);
				if (fn.byteSliceName != null) result.set(fn.byteSliceName, origin);
			}
			result.set(profile.functionModule == null ? plan.source.name : profile.functionModule, plan.source.span);
		}
		if (constants) {
			var container = plan.source.name.substr(0, 1).toUpperCase() + plan.source.name.substr(1) + "Constants";
			result.set(container, plan.source.span);
			for (declaration in plan.source.declarations) switch declaration {
				case Constant(name, _, origin) if (!HxiHaxeEmitter.isOmitted(plan.omitted, name)):
					result.set(container + "." + HxiHaxeEmitter.projectedConstantName(name, profile), origin);
				case _:
			}
		}
		return result;
	}

	static function span(declaration:HxiDeclaration):SourceSpan
		return switch declaration {
			case Opaque(_, span) | Alias(_, _, span) | Handle(_, _, _, span) | Constant(_, _, span) | Structure(_, _, _, _, span) |
				Enumeration(_, _, _, _, span) | Callback(_, _, _, _, span) | Function(_, _, _, _, _, _, _, span): span;
		};
}
