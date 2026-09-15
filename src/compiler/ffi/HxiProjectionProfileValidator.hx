package compiler.ffi;

import compiler.ffi.HxiModel.HxiDeclaration;
import compiler.ffi.HxiModel.HxiInterface;
import compiler.ffi.HxiProjectionProfile;

/** Validates the Haxe presentation profile independently from native ABI semantics. */
class HxiProjectionProfileValidator {
	static function has<T>(values:Array<T>, predicate:T->Bool):Bool {
		for (value in values)
			if (predicate(value))
				return true;
		return false;
	}

	/** Validate Haxe naming rules against the declarations the profile can project. */
	public static function validate(path:String, model:HxiInterface, ?omitted:Map<String, Bool>, ?visibleDeclarations:Map<String, HxiDeclaration>,
			profile:HxiProjectionProfile):Void {
		if (profile.interfaceName != model.name)
			HxiHaxeEmitter.profileError(path, 'names interface "${profile.interfaceName}" but was applied to "${model.name}"');

		var declarations:Map<String, HxiDeclaration> = [],
			local:Map<String, HxiDeclaration> = [];
		if (visibleDeclarations != null)
			for (name => declaration in visibleDeclarations)
				declarations.set(name, declaration);
		for (declaration in model.declarations) {
			var name = HxiHaxeEmitter.declarationName(declaration);
			declarations.set(name, declaration);
			local.set(name, declaration);
		}

		for (name in HxiHaxeEmitter.sortedKeys(profile.typeNames)) {
			var declaration = declarations.get(name),
				entry = 'typeNames.$name';
			if (declaration == null)
				HxiHaxeEmitter.profileError(path, '$entry references unknown HXI type "$name"');
			if (!HxiHaxeEmitter.isProjectedType(declaration))
				HxiHaxeEmitter.profileError(path, '$entry refers to "$name", which has no generated Haxe type');
			HxiHaxeEmitter.validateTypePath(path, entry, profile.typeNames.get(name), local.exists(name)
				&& !HxiHaxeEmitter.isOmitted(omitted, name));
		}
		for (name in HxiHaxeEmitter.sortedKeys(profile.enumNames)) {
			var declaration = declarations.get(name),
				entry = 'enumNames.$name';
			if (declaration == null)
				HxiHaxeEmitter.profileError(path, '$entry references unknown HXI enum "$name"');
			if (!HxiHaxeEmitter.isEnumeration(declaration))
				HxiHaxeEmitter.profileError(path, '$entry refers to "$name", which is not an enum');
			HxiHaxeEmitter.validateTypePath(path, entry, profile.enumNames.get(name), local.exists(name)
				&& !HxiHaxeEmitter.isOmitted(omitted, name));
			var typeName = profile.typeNames.get(name);
			if (typeName != null && typeName != profile.enumNames.get(name))
				HxiHaxeEmitter.profileError(path, '$entry conflicts with typeNames.$name');
		}
		for (enumName in HxiHaxeEmitter.sortedKeys(profile.enumValueNames)) {
			var declaration = declarations.get(enumName),
				entry = 'enumValueNames.$enumName';
			if (declaration == null)
				HxiHaxeEmitter.profileError(path, '$entry references unknown HXI enum "$enumName"');
			var values = switch declaration {
				case Enumeration(_, _, _, values, _): values;
				case _:
					HxiHaxeEmitter.profileError(path, '$entry refers to "$enumName", which is not an enum');
					[];
			};
			if (!local.exists(enumName) || HxiHaxeEmitter.isOmitted(omitted, enumName))
				HxiHaxeEmitter.profileError(path, '$entry refers to an enum projected by a dependency; rename its values in that interface profile');
			var valueNames:Map<String, Bool> = [for (value in values) value.name => true];
			var projectedValueNames:Map<String, String> = cast profile.enumValueNames.get(enumName);
			for (valueName in HxiHaxeEmitter.sortedKeys(projectedValueNames)) {
				if (!valueNames.exists(valueName))
					HxiHaxeEmitter.profileError(path, '$entry.$valueName references an unknown enum value');
				HxiHaxeEmitter.validateEnumValueIdentifier(path, '$entry.$valueName', projectedValueNames.get(valueName));
			}
		}
		for (name in HxiHaxeEmitter.sortedKeys(profile.functionNames)) {
			var declaration = local.get(name), entry = 'functionNames.$name';
			if (declaration == null)
				HxiHaxeEmitter.profileError(path, '$entry references an unknown function in this interface');
			if (!HxiHaxeEmitter.isFunction(declaration) || HxiHaxeEmitter.isOmitted(omitted, name))
				HxiHaxeEmitter.profileError(path, '$entry does not refer to a function projected by this interface');
			HxiHaxeEmitter.validateIdentifier(path, entry, profile.functionNames.get(name));
		}
		for (key in HxiHaxeEmitter.sortedKeys(profile.fieldNames)) {
			var separator = key.indexOf("."),
				typeName = separator < 0 ? "" : key.substr(0, separator),
				fieldName = separator < 0 ? "" : key.substr(separator + 1),
				entry = 'fieldNames.$typeName.$fieldName',
				declaration = local.get(typeName);
			if (separator <= 0 || separator == key.length - 1)
				HxiHaxeEmitter.profileError(path, 'fieldNames key "$key" must have the form "type.field"');
			var fields:Array<compiler.ffi.HxiModel.HxiField> = switch declaration {
				case Structure(_, _, _, fields, _) if (!HxiHaxeEmitter.isOmitted(omitted, typeName)): fields;
				case null:
					HxiHaxeEmitter.profileError(path, '$entry references an unknown structure in this interface');
					[];
				case _:
					HxiHaxeEmitter.profileError(path, '$entry does not refer to a structure projected by this interface');
					[];
			};
			var fieldFound = false;
			for (field in fields)
				if (field.name == fieldName)
					fieldFound = true;
			if (!fieldFound)
				HxiHaxeEmitter.profileError(path, '$entry references an unknown structure field');
			HxiHaxeEmitter.validateIdentifier(path, entry, profile.fieldNames.get(key));
		}
		for (name in HxiHaxeEmitter.sortedKeys(profile.constantNames)) {
			var declaration = local.get(name), entry = 'constantNames.$name';
			if (declaration == null)
				HxiHaxeEmitter.profileError(path, '$entry references an unknown constant in this interface');
			if (!HxiHaxeEmitter.isConstant(declaration) || HxiHaxeEmitter.isOmitted(omitted, name))
				HxiHaxeEmitter.profileError(path, '$entry does not refer to a constant projected by this interface');
			HxiHaxeEmitter.validateIdentifier(path, entry, profile.constantNames.get(name));
		}
		for (name in HxiHaxeEmitter.sortedKeys(profile.resultPolicies)) {
			var entry = 'resultPolicies.$name',
				declaration = local.get(name),
				policy:compiler.ffi.HxiProjectionProfile.HxiResultErrorProjection = cast profile.resultPolicies.get(name),
				values:Array<compiler.ffi.HxiModel.HxiEnumValue> = switch declaration {
					case Enumeration(_, _, _, values, _): values;
					case null:
						HxiHaxeEmitter.profileError(path, '$entry references an unknown result enum in this interface');
						[];
					case _:
						HxiHaxeEmitter.profileError(path, '$entry does not refer to an enum in this interface');
						[];
				};
			var valueFound = false;
			for (value in values)
				if (value.name == policy.successValue)
					valueFound = true;
			if (!valueFound)
				HxiHaxeEmitter.profileError(path, '$entry.successValue references an unknown enum value');
			var resultMatches = false;
			for (candidate in model.declarations)
				switch candidate {
					case Function(_, _, resultType, _, _, _, _, _):
						switch resultType {
							case Named(resultName) if (resultName == name): resultMatches = true;
							case _:
						};
					case _:
				}
			if (!resultMatches)
				HxiHaxeEmitter.profileError(path, '$entry does not match the result type of any function in this interface');
			if (policy.checkedSuffix.length == 0)
				HxiHaxeEmitter.profileError(path, '$entry.checkedSuffix must not be empty');
			HxiHaxeEmitter.validateTypePath(path, '$entry.errorType', policy.errorType, false);
			if (policy.diagnosticFunction != null) {
				if (HxiHaxeEmitter.isOmitted(omitted, policy.diagnosticFunction))
					HxiHaxeEmitter.profileError(path, '$entry cannot use omitted diagnostic function "${policy.diagnosticFunction}"');
				var diagnostic = local.get(policy.diagnosticFunction);
				switch diagnostic {
					case Function(_, parameters, resultType, _, _, _, _, _):
						var isUtf8 = switch resultType {
							case Primitive(name): name == "utf8";
							case _: false;
						};
						if (parameters.length != 0 || !isUtf8)
							HxiHaxeEmitter.profileError(path, '$entry.diagnosticFunction must be a zero-argument UTF-8 function in this interface');
					case null:
						HxiHaxeEmitter.profileError(path, '$entry.diagnosticFunction references an unknown function in this interface');
					case _:
						HxiHaxeEmitter.profileError(path, '$entry.diagnosticFunction must be a zero-argument UTF-8 function in this interface');
				}
			}
		}

		var moduleNames:Map<String, String> = [],
			constantMembers:Map<String, String> = [],
			hasCallbacks = false,
			hasOpaqueTypes = false,
			hasOwnedPointerOutputs = false,
			hasConstants = false;
		for (declaration in model.declarations)
			if (!HxiHaxeEmitter.isOmitted(omitted, HxiHaxeEmitter.declarationName(declaration)))
				switch declaration {
					case Callback(_, _, _, _, _):
						hasCallbacks = true;
					case Opaque(_, _):
						hasOpaqueTypes = true;
					case Function(_, parameters, _, _, _, _, _, _):
						for (parameter in parameters)
							switch parameter.ownership {
								case Owned(_): hasOwnedPointerOutputs = true;
								case Borrowed | Unspecified:
							}
					case Constant(_, _, _):
						hasConstants = true;
					case _:
				}
		if (hasCallbacks)
			HxiHaxeEmitter.addProjectedName(path, "module", "HxiCallbackError", "generated callback error type", moduleNames);
		if (hasOpaqueTypes) {
			HxiHaxeEmitter.addProjectedName(path, "module", '__hxi_${model.name}_native_pointer_close', "opaque handle close helper", moduleNames);
			HxiHaxeEmitter.addProjectedName(path, "module", '__hxi_${model.name}_native_pointer_is_closed', "opaque handle state helper", moduleNames);
		}
		if (hasOwnedPointerOutputs)
			HxiHaxeEmitter.addProjectedName(path, "module", '__hxi_${model.name}_native_pointer_owned_from_slot', "owned opaque output helper", moduleNames);
		if (hasConstants)
			HxiHaxeEmitter.addProjectedName(path, "module", HxiHaxeEmitter.upperFirst(model.name) + "Constants", "generated constants type", moduleNames);

		for (declaration in model.declarations) {
			var declarationName = HxiHaxeEmitter.declarationName(declaration);
			if (HxiHaxeEmitter.isOmitted(omitted, declarationName))
				continue;
			switch declaration {
				case Callback(name, _, _, _, _):
					var projected = HxiHaxeEmitter.projectedTypeName(name, profile);
					HxiHaxeEmitter.addProjectedName(path, "module", projected, 'callback "$name"', moduleNames);
					HxiHaxeEmitter.addProjectedName(path, "module", projected + "Callback", 'callback wrapper for "$name"', moduleNames);
				case Enumeration(name, _, _, values, _):
					HxiHaxeEmitter.addProjectedName(path, "module", HxiHaxeEmitter.enumTypeName(name, profile), 'enum "$name"', moduleNames);
					var members:Map<String, String> = [],
						prefix = HxiHaxeEmitter.enumValuePrefix(values, profile);
					for (value in values)
						HxiHaxeEmitter.addProjectedName(path, 'enum "$name"', HxiHaxeEmitter.enumValueName(value.name, prefix, name, profile),
							'enum value "$name.${value.name}"', members, true);
				case Opaque(name, _):
					HxiHaxeEmitter.addProjectedName(path, "module", HxiHaxeEmitter.projectedTypeName(name, profile), 'opaque type "$name"', moduleNames);
					HxiHaxeEmitter.addProjectedName(path, "module", HxiHaxeEmitter.ownedTypeName(name, profile), 'owned opaque type "$name"', moduleNames);
				case Handle(name, _, destroySymbol, _):
					HxiHaxeEmitter.addProjectedName(path, "module", HxiHaxeEmitter.projectedTypeName(name, profile), 'type "$name"', moduleNames);
					if (destroySymbol != null) {
						HxiHaxeEmitter.addProjectedName(path, "module", HxiHaxeEmitter.ownedTypeName(name, profile), 'owned value handle "$name"', moduleNames);
						var destroyName = HxiHaxeEmitter.functionNameForSymbol(model.declarations, destroySymbol);
						if (HxiHaxeEmitter.isOmitted(omitted, destroyName))
							HxiHaxeEmitter.profileError(path, 'cannot omit destroy function "$destroyName" while projecting owned value handle "$name"');
					}
				case Structure(name, _, _, fields, _):
					HxiHaxeEmitter.addProjectedName(path, "module", HxiHaxeEmitter.projectedTypeName(name, profile), 'type "$name"', moduleNames);
					var members:Map<String, String> = [];
					for (field in fields)
						HxiHaxeEmitter.addProjectedName(path, 'structure "$name"', HxiHaxeEmitter.projectedFieldName(name, field.name, profile),
							'structure field "$name.${field.name}"', members);
				case Function(name, parameters, result, _, _, _, _, _):
					var publicName = HxiHaxeEmitter.projectedFunctionName(name, profile);
					HxiHaxeEmitter.addProjectedName(path, "module", publicName, 'function "$name"', moduleNames);
					var resultPolicy = HxiHaxeEmitter.resultErrorProjection(result, profile);
					if (resultPolicy != null)
						HxiHaxeEmitter.addProjectedName(path, "module", publicName + resultPolicy.checkedSuffix, 'checked result wrapper for "$name"',
							moduleNames);
					if (HxiHaxeEmitter.hasOutput(parameters))
						HxiHaxeEmitter.addProjectedName(path, "module", '__hxi_raw_$name', 'raw wrapper for "$name"', moduleNames);
					if (HxiHaxeEmitter.hasGeneratedOutputResult(parameters, result))
						HxiHaxeEmitter.addProjectedName(path, "module", HxiHaxeEmitter.upperFirst(publicName) + "OutResult", 'output result type for "$name"',
							moduleNames);
					if (HxiHaxeEmitter.byteArrayParameter(parameters) != null)
						HxiHaxeEmitter.addProjectedName(path, "module", publicName + "_slice", 'byte-slice wrapper for "$name"', moduleNames);
				case Constant(name, _, _):
					HxiHaxeEmitter.addProjectedName(path, "constants", HxiHaxeEmitter.projectedConstantName(name, profile), 'constant "$name"',
						constantMembers);
				case _:
			}
		}
	}
}
