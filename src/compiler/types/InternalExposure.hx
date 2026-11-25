package compiler.types;

import compiler.core.Diagnostic;
import compiler.core.Diagnostic.CompileError;
import compiler.core.DiagnosticCode;
import compiler.core.Source.SourceSpan;
import compiler.syntax.Ast;

/**
 * A declaration other packages can use may not name an `internal` type in what they see of it (`E1031`): its supertypes,
 * type parameters' constraints, a typedef's type, an abstract's underlying and conversion types, an enum constructor's
 * arguments, and the types of its public members. Otherwise a package's user would hold a value whose type it cannot name,
 * and the package could no longer change that type freely. An internal declaration, a private one and a private member may
 * name internal types. Uses from another package are `InternalAccess`'s.
 */
class InternalExposure {
	public static function check(program:AstProgram, internalTypes:Map<String, SourceSpan>):Void {
		if (!internalTypes.iterator().hasNext())
			return;
		var exposure = new InternalExposure(internalTypes);
		for (decl in program.classes ?? [])
			if (!decl.isPrivate && decl.isInternal != true) {
				var what = 'Class ${decl.name}',
					publicByDefault = decl.isExtern == true || has(decl.metadata, "publicFields");
				if (decl.base != null)
					exposure.type(decl.base, what, decl.span);
				exposure.types(decl.interfaces, what, decl.span);
				exposure.constraints(decl.typeConstraints, what);
				for (field in decl.fields ?? [])
					if (visible(field.isPublic, field.isInternal, publicByDefault))
						exposure.field(field, '${decl.name}.${field.name}');
				for (method in decl.methods ?? [])
					if (visible(method.isPublic, method.isInternal, publicByDefault) && !inheritsVisibility(method))
						exposure.signature(method, '${decl.name}.${method.name}');
			}
		for (decl in program.interfaces ?? [])
			if (decl.isInternal != true) {
				var what = 'Interface ${decl.name}';
				exposure.types(decl.bases, what, decl.span);
				exposure.constraints(decl.typeConstraints, what);
				for (field in decl.fields ?? [])
					exposure.field(field, '${decl.name}.${field.name}');
				for (method in decl.methods ?? [])
					if (method.sourcePrivate != true)
						exposure.signature(method, '${decl.name}.${method.name}');
			}
		for (decl in program.aliases ?? [])
			if (!decl.isPrivate && decl.isInternal != true) {
				exposure.type(decl.type, 'Typedef ${decl.name}', decl.span);
				exposure.constraints(decl.typeConstraints, 'Typedef ${decl.name}');
			}
		for (decl in program.enums ?? [])
			if (decl.isInternal != true) {
				exposure.constraints(decl.typeConstraints, 'Enum ${decl.name}');
				for (entry in decl.cases ?? [])
					for (parameter in entry.params ?? [])
						exposure.type(parameter.type, '${decl.name}.${entry.name}', entry.span);
				for (method in decl.methods ?? [])
					if (visible(method.isPublic, method.isInternal, false))
						exposure.signature(method, '${decl.name}.${method.name}');
			}
		for (decl in program.abstracts ?? [])
			if (decl.isInternal != true) {
				var what = 'Abstract ${decl.name}',
					publicByDefault = decl.isExtern == true || has(decl.metadata, "publicFields");
				exposure.type(decl.underlying, what, decl.span);
				exposure.types(decl.fromTypes, what, decl.span);
				exposure.types(decl.toTypes, what, decl.span);
				exposure.constraints(decl.typeConstraints, what);
				for (field in decl.fields ?? [])
					if (visible(field.isPublic, field.isInternal, publicByDefault))
						exposure.field(field, '${decl.name}.${field.name}');
				for (method in decl.methods ?? [])
					if (visible(method.isPublic, method.isInternal, publicByDefault))
						exposure.signature(method, '${decl.name}.${method.name}');
			}
		// A module's own variables and functions are public unless written otherwise.
		for (field in program.fields ?? [])
			if (visible(field.isPublic, field.isInternal, true))
				exposure.field(field, field.name);
		for (fn in program.functions ?? [])
			if (visible(fn.isPublic, fn.isInternal, true))
				exposure.signature(fn, fn.name);
	}

	final internalTypes:Map<String, SourceSpan>;

	function new(internalTypes:Map<String, SourceSpan>)
		this.internalTypes = internalTypes;

	/** Whether a member written with `isPublic` and `isInternal` is seen by other packages, public when unwritten if `byDefault`. */
	static function visible(isPublic:Null<Bool>, isInternal:Null<Bool>, byDefault:Bool):Bool
		return isInternal != true && (isPublic ?? byDefault);

	/** An override written without a modifier has the visibility of what it overrides, whose signature is checked there. */
	static function inheritsVisibility(method:AstFunction):Bool
		return method.isOverride == true && method.isPublic == null;

	function field(field:AstField, what:String):Void
		if (field.type != null)
			type(field.type, what, field.span);

	function signature(fn:AstFunction, what:String):Void {
		for (argument in fn.arguments ?? [])
			type(argument.type, what, fn.span);
		type(fn.result, what, fn.span);
		constraints(fn.typeConstraints, what);
	}

	function constraints(entries:Null<Array<AstTypeConstraint>>, what:String):Void
		for (entry in entries ?? [])
			type(entry.type, what, entry.span);

	function types(entries:Null<Array<AstType>>, what:String, span:SourceSpan):Void
		for (entry in entries ?? [])
			type(entry, what, span);

	function type(value:AstType, what:String, span:SourceSpan):Void
		switch value {
			case NamedType(name):
				require(name, what, span);
			case AppliedType(name, arguments):
				require(name, what, span);
				types(arguments, what, span);
			case ArrayType(element), NullableType(element):
				type(element, what, span);
			case MapType(key, element):
				type(key, what, span);
				type(element, what, span);
			case FunctionType(arguments, result, _):
				types(arguments, what, span);
				type(result, what, span);
			case AnonymousType(fields):
				for (field in fields)
					type(field.type, what, field.span);
			case IntType, BoolType, FloatType, StringType, VoidType, InferredType, ErrorType(_),
				NativeAbstractType(_, _):
		}

	function require(name:String, what:String, span:SourceSpan):Void
		if (internalTypes.exists(name))
			throw new CompileError(new Diagnostic(DiagnosticCode.INTERNAL_ACCESS,
				'$what is public but exposes $name, which is internal: make it internal too, or keep $name out of it',
				span));

	static function has(metadata:Null<Array<AstMetadata>>, name:String):Bool {
		for (entry in metadata ?? [])
			if (entry.name == name)
				return true;
		return false;
	}
}
