package compiler.types.typing;

import compiler.core.Source.SourceSpan;
import compiler.syntax.Ast.AstClass;
import compiler.syntax.Ast.AstField;
import compiler.types.TypedAst.TypedExpression;
import compiler.types.TypedAst.TypedField;
import compiler.types.TypedAst.TypedFunction;
import compiler.types.TypedAst.TypedStatement;
import compiler.types.TypedChildren;

/**
 * Haxe's null-safety rules for a checked class's fields (`check_var_fields` in `nullSafety.ml`): a field that does not take null
 * has a value once its class is made. A static needs an initial value; an instance field one, or an assignment in the
 * constructor, which may not use `this`, call a method or read such a field before every one is assigned. It reads the typed
 * constructor as Haxe reads its typed one, so it follows the same simple flow: assignments in sequence and in both branches of an
 * `if` with an `else`; anything else that mentions an unassigned field is a use.
 */
class NullSafetyInitialization {
	/**
	 * Checks `classDecl`, whose typed fields are `fields`. `constructor` is its constructor as this compile typed it, or null when
	 * it has none or did not type it again (`constructorTyped`), in which case what the constructor assigns was checked before.
	 */
	public static function check(session:TypingSession, classDecl:AstClass, fields:Array<TypedField>,
			constructor:Null<TypedFunction>, constructorTyped:Bool):Void {
		if (classDecl.isExtern == true)
			return;
		var checker = session.nullSafety, classMode = checker.declarationMode(classDecl.name);
		if (classMode.mode == Off)
			return;
		var warnings = constructor == null ? null : constructor.warnings,
			warns = classMode.warns,
			unassigned:Array<AstField> = [];
		function report(message:String, span:SourceSpan)
			checker.reportFor(warns, message, span, warnings);
		for (field in classDecl.fields) {
			if (!isStored(field) || NullSafety.turnsOff(field.metadata))
				continue;
			var typed = typedField(fields, field);
			if (typed == null || NullSafety.acceptsNull(typed.type) || field.initializer != null)
				continue;
			if (field.isStatic)
				report('Field "${field.name}" is not nullable thus should have an initial value.',
					declarationSpan(field));
			else
				unassigned.push(field);
		}
		if (unassigned.length == 0 || (!constructorTyped && hasConstructor(classDecl)))
			return;
		var pending:Map<String, Bool> = [for (field in unassigned) field.name => true];
		if (constructor != null)
			pending = new ConstructorFlow(report).assign(constructor.statements, pending);
		for (field in unassigned)
			if (pending.exists(field.name))
				report('Field "${field.name}" is not nullable thus should have an initial value or should be initialized in constructor.',
					declarationSpan(field));
	}

	static function hasConstructor(classDecl:AstClass):Bool {
		for (method in classDecl.methods)
			if (method.name == "new")
				return true;
		return false;
	}

	/** Haxe's `should_be_initialized`: a variable with storage, as a property with no plain read or write has none. */
	static function isStored(field:AstField):Bool {
		function plain(access:Null<compiler.syntax.Ast.AstFieldAccess>):Bool
			return access == null || access.match(DefaultAccess | NullAccess);
		if (plain(field.readAccess) || plain(field.writeAccess))
			return true;
		for (entry in field.metadata)
			if (entry.name == "isVar")
				return true;
		return false;
	}

	static function typedField(fields:Array<TypedField>, field:AstField):Null<TypedField> {
		for (typed in fields)
			if (typed.name == field.name && typed.isStatic == field.isStatic)
				return typed;
		return null;
	}

	static function declarationSpan(field:AstField):SourceSpan
		return field.declarationSpan == null ? field.span : field.declarationSpan;
}

/** The constructor's walk: which fields are still unassigned at each point, and what uses them before that. */
private class ConstructorFlow {
	final report:(String, SourceSpan) -> Void;

	/** Locals the constructor set to `this`, which are `this`. */
	final aliases:Map<String, Bool> = [];

	public function new(report:(String, SourceSpan) -> Void)
		this.report = report;

	/** The fields of `pending` still unassigned after `statements`. */
	public function assign(statements:Array<TypedStatement>, pending:Map<String, Bool>):Map<String, Bool> {
		for (statement in statements)
			pending = assignStatement(statement, pending);
		return pending;
	}

	function assignStatement(statement:TypedStatement, pending:Map<String, Bool>):Map<String, Bool> {
		switch statement {
			case TFieldAssign(object, name, value, _) if (isThis(object)):
				pending.remove(name);
				use(value, pending);
			case TDoWhile(body, condition, _):
				use(condition, pending);
				pending = assign(body, pending);
			case TIf(_, thenBranch, elseBranch, _) if (elseBranch.length > 0):
				var afterThen = assign(thenBranch, pending.copy()), afterElse = assign(elseBranch, pending.copy());
				pending = afterThen;
				for (name in afterElse.keys())
					pending.set(name, true);
			case TExpression(value, _) if (value.expression.match(TBlockExpression(_, _))):
				switch value.expression {
					case TBlockExpression(body, result):
						pending = assign(body, pending);
						use(result, pending);
					default:
				}
			case TVar(name, value, _) if (isThis(value)):
				aliases.set(name, true);
			default:
				useStatement(statement, pending);
		}
		return pending;
	}

	function useStatement(statement:TypedStatement, pending:Map<String, Bool>):Void {
		if (!pending.keys().hasNext())
			return;
		switch statement {
			// An assignment that is not one of the constructor's own steps (inside an `if` without `else`, a loop) is a use, as in Haxe.
			case TFieldAssign(object, name, value, span) if (isThis(object)):
				if (pending.exists(name))
					report('Cannot use field $name until initialization.', span);
				use(value, pending);
			default:
				TypedChildren.ofStatement(statement, value -> use(value, pending),
					list -> useStatements(list, pending));
		}
	}

	function useStatements(statements:Array<TypedStatement>, pending:Map<String, Bool>):Void
		for (statement in statements)
			useStatement(statement, pending);

	function use(value:TypedExpression, pending:Map<String, Bool>):Void {
		if (!pending.keys().hasNext())
			return;
		switch value.expression {
			case TField(object, name) if (isThis(object)):
				if (pending.exists(name))
					report('Cannot use field $name until initialization.', value.span);
			case TMethodRef(object, method) if (isThis(object)):
				report('Cannot use method ${memberName(method)} until all instance fields are initialized.',
					value.span);
			case TMethodCall(object, method, arguments) if (isThis(object)):
				report('Cannot call method ${memberName(method)} until all instance fields are initialized.',
					value.span);
				for (argument in arguments)
					use(argument, pending);
			case TLocal(_) if (isThis(value)):
				report('Cannot use "this" until all instance fields are initialized.', value.span);
			default:
				TypedChildren.ofExpression(value.expression, child -> use(child, pending),
					list -> useStatements(list, pending));
		}
	}

	function isThis(value:TypedExpression):Bool
		return switch value.expression {
			case TLocal(id): id == "this" || StringTools.endsWith(id, ":this") || aliases.exists(id);
			case TCast(inner): isThis(inner);
			default: false;
		};

	static function memberName(method:String):String
		return method.substr(method.lastIndexOf(".") + 1);
}
