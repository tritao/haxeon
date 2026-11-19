package compiler.types.analysis;

import compiler.core.Diagnostic;
import compiler.core.Diagnostic.CompileError;
import compiler.core.Source.SourceSpan;
import compiler.syntax.Ast.AstArgument;
import compiler.syntax.Ast.AstExpression;
import compiler.syntax.Ast.AstStatement;
import compiler.types.analysis.BindingWalker.BindingKind;

/** Checks direct, lexical escapes of scoped bindings without treating calls as ownership contracts. */
class ScopedEscapeChecker extends BindingWalker {
	final scopedDepth:Map<String, Int> = [];

	public static function check(arguments:Array<AstArgument>, body:Array<AstStatement>):Void {
		var checker = new ScopedEscapeChecker();
		checker.walkFunction(arguments, body);
	}

	override function statement(value:AstStatement):Void {
		switch value {
			case ScopedDeclaration(name, _, _, span): scopedDepth.set(BindingWalker.key(name, span), lambdaDepth);
			case VarDeclaration(_, _, initializer, _): rejectDirect(initializer, "stored in a local");
			case Return(expression, _): rejectDirect(expression, "returned");
			case Assignment(_, expression, _), FieldAssignment(_, _, expression, _),
				IndexAssignment(_, _, expression, _):
				rejectDirect(expression, "stored");
			default:
		}
		super.statement(value);
	}

	override function expression(value:AstExpression):Void {
		switch value {
			case ArrayLiteral(values, _): for (item in values) rejectDirect(item, "stored in an array");
			case MapLiteral(entries, _): for (item in entries) {
					rejectDirect(item.key, "stored in a map");
					rejectDirect(item.value, "stored in a map");
				}
			case ObjectLiteral(fields, _): for (field in fields) rejectDirect(field.value, "stored in an object");
			case ArrayComprehension(keyName, valueName, _, _, item, _, span):
				var scope = enterScope();
				declare(keyName, span, Comprehension);
				if (valueName != null) declare(valueName, span, Comprehension);
				rejectDirect(item, "stored in an array");
				leaveScope(scope);
			case MapComprehension(keyName, valueName, _, _, key, item, span):
				var scope = enterScope();
				declare(keyName, span, Comprehension);
				if (valueName != null) declare(valueName, span, Comprehension);
				rejectDirect(key, "stored in a map");
				rejectDirect(item, "stored in a map");
				leaveScope(scope);
			case Cast(inner, NamedType("Dynamic"), _), CheckType(inner, NamedType("Dynamic"), _):
				rejectDirect(inner, "converted to Dynamic");
			default:
		}
		super.expression(value);
	}

	override function used(name:String, declaration:Null<String>, span:SourceSpan):Void {
		if (declaration != null && scopedDepth.exists(declaration) && lambdaDepth > scopedDepth.get(declaration))
			reject(name, "captured by a closure", span);
	}

	override function written(name:String, declaration:Null<String>, span:SourceSpan):Void {
		if (declaration != null && scopedDepth.exists(declaration) && name.indexOf(".") < 0)
			reject(name, "reassigned", span);
	}

	function rejectDirect(value:AstExpression, operation:String):Void {
		switch value {
			case Variable(name, span):
				var declaration = resolve(name);
				if (declaration != null && scopedDepth.exists(declaration)) reject(name, operation, span);
			case Conditional(_, yes, no, _):
				rejectDirect(yes, operation);
				rejectDirect(no, operation);
			case Cast(inner, _, _), CheckType(inner, _, _): rejectDirect(inner, operation);
			// The value of an assignment is the value it stores.
			case AssignmentValue(Assignment(_, stored, _) | FieldAssignment(_, _, stored, _)
				| IndexAssignment(_, _, stored, _), _):
				rejectDirect(stored, operation);
			case BlockExpression(statements, result, _):
				var scope = enterScope();
				for (statement in statements) this.statement(statement);
				rejectDirect(result, operation);
				leaveScope(scope);
			case SwitchExpression(_, cases, fallback, _):
				for (arm in cases) {
					var scope = enterScope();
					for (pattern in arm.patterns)
						bindPattern(pattern, arm.span);
					rejectDirect(arm.result, operation);
					leaveScope(scope);
				}
				if (fallback != null) rejectDirect(fallback, operation);
			default:
		}
	}

	static function reject(name:String, operation:String, span:SourceSpan):Void
		throw new CompileError(new Diagnostic("E1002", 'Scoped binding "$name" cannot be $operation', span));
}
