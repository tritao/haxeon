package compiler.types;

import compiler.syntax.Ast.AstClass;
import compiler.syntax.Ast.AstField;
import compiler.syntax.Ast.AstType;
import compiler.types.Type.CompilerType;
import compiler.types.Type.NominalKind;

/** Inferred representation facts and the first field path that violates each one. */
typedef StructPropertyFacts = {
	final flat:Bool;
	final portable:Bool;
	final flatPath:Null<String>;
	final portablePath:Null<String>;
}

/** Compiler-owned representation constraints shared by typing and generic checks. */
class StructProperties {
	public static inline final FLAT_TYPE_NAME = "$haxeon.Flat";
	public static inline final PORTABLE_TYPE_NAME = "$haxeon.Portable";

	public static function sourceConstraintName(name:String):Null<String>
		return switch name {
			case "Flat": FLAT_TYPE_NAME;
			case "Portable": PORTABLE_TYPE_NAME;
			default: null;
		};

	public static function isConstraintName(name:String):Bool
		return name == FLAT_TYPE_NAME || name == PORTABLE_TYPE_NAME;

	public static function isConstraintSyntax(type:AstType):Bool
		return switch type {
			case NamedType(name) | AppliedType(name, _): sourceConstraintName(name) != null;
			case _: false;
		};

	public static function isConstraintType(type:CompilerType):Bool
		return switch type {
			case TInstance(NominalKind.Interface, name, _): isConstraintName(name);
			default: false;
		};

	public static function evaluate(declarations:DeclarationIndex, type:CompilerType):StructPropertyFacts
		return evaluateAt(declarations, type, "", []);

	public static function satisfies(declarations:DeclarationIndex, type:CompilerType, constraintName:String):Bool {
		var facts = evaluate(declarations, type);
		return constraintName == FLAT_TYPE_NAME ? facts.flat : constraintName == PORTABLE_TYPE_NAME && facts.portable;
	}

	public static function failurePath(declarations:DeclarationIndex, type:CompilerType, constraintName:String):Null<String> {
		var facts = evaluate(declarations, type);
		return constraintName == FLAT_TYPE_NAME ? facts.flatPath : facts.portablePath;
	}

	static function evaluateAt(declarations:DeclarationIndex, type:CompilerType, path:String, visiting:Array<String>):StructPropertyFacts
		return switch type {
			case TInt | TInt64 | TBool | TFloat:
				{
					flat: true,
					portable: true,
					flatPath: null,
					portablePath: null
				};
			case TAbstract(name, _, representation) if (isRawPointer(name)):
				{
					flat: true,
					portable: false,
					flatPath: null,
					portablePath: path
				};
			case TAbstract(_, _, representation):
				evaluateAt(declarations, representation, path, visiting);
			case TInstance(NominalKind.Class, name, _):
				var declaration = declarations.classes.get(name);
				if (declaration == null || !isValueDeclaration(declaration)) invalid(path) else evaluateDeclaration(declarations, declaration, path, visiting);
			case TInstance(NominalKind.NativeValue, name, _):
				var declaration = declarations.classes.get(name);
				if (declaration == null) invalid(path) else evaluateDeclaration(declarations, declaration, path, visiting);
			case TNativeScalar(name):
				var portable = !isTargetDependentScalarName(name);
				{
					flat: true,
					portable: portable,
					flatPath: null,
					portablePath: portable ? null : path
				};
			case _:
				invalid(path);
		};

	static function evaluateDeclaration(declarations:DeclarationIndex, declaration:AstClass, path:String, visiting:Array<String>):StructPropertyFacts {
		if (visiting.indexOf(declaration.name) >= 0)
			return invalid(path.length == 0 ? declaration.name : path);
		var nextPath = path.length == 0 ? declaration.name : path, flat = true, portable = true, flatPath:Null<String> = null,
			portablePath:Null<String> = null, nextVisiting = visiting.concat([declaration.name]);
		for (field in declaration.fields)
			if (!field.isStatic && hasStorage(field)) {
				var fieldPath = nextPath.length == 0 ? field.name : nextPath + "." + field.name,
					fieldType = declarations.resolve(declarations.resolvedFieldType(declaration.name, field), field.span),
					facts = evaluateAt(declarations, fieldType, fieldPath, nextVisiting);
				if (!facts.flat) {
					flat = false;
					if (flatPath == null)
						flatPath = facts.flatPath == null ? fieldPath : facts.flatPath;
				}
				if (!facts.portable) {
					portable = false;
					if (portablePath == null)
						portablePath = facts.portablePath == null ? fieldPath : facts.portablePath;
				}
			}
		return {
			flat: flat,
			portable: portable && flat,
			flatPath: flatPath,
			portablePath: portable ? null : portablePath == null ? flatPath : portablePath
		};
	}

	static function invalid(path:String):StructPropertyFacts
		return {
			flat: false,
			portable: false,
			flatPath: path,
			portablePath: path
		};

	static function isValueDeclaration(declaration:AstClass):Bool {
		if (declaration.isStruct == true)
			return true;
		for (metadata in declaration.metadata)
			if (metadata.name == "value")
				return true;
		return false;
	}

	static function hasStorage(field:AstField):Bool {
		if (hasDirectAccess(field.readAccess) || hasDirectAccess(field.writeAccess))
			return true;
		for (metadata in field.metadata)
			if (metadata.name == "isVar")
				return true;
		return false;
	}

	static function hasDirectAccess(access:Null<compiler.syntax.Ast.AstFieldAccess>):Bool
		return switch access {
			case GetAccess, SetAccess, NeverAccess: false;
			default: true;
		};

	static function isRawPointer(name:String):Bool
		return name == "RawPtr" || StringTools.endsWith(name, ".RawPtr");

	static function isTargetDependentScalarName(name:String):Bool
		return switch name {
			case "c_long" | "c_ulong" | "c_size" | "c_wchar": true;
			case _: false;
		};
}
