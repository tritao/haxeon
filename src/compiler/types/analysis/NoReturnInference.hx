package compiler.types.analysis;

import compiler.syntax.Ast;

/**
 * Infers which functions never return: every path throws, or forwards unconditionally to
 * another never-returning call. Purely syntactic over canonical signatures, so it can run
 * before typing, on the current program state, to detect a caller whose never-returns answer
 * for some callee has changed since the caller was last typed.
 */
class NoReturnInference {
	public static function infer(signatures:Map<String, AstFunction>, overridden:Map<String, Bool>):Map<String, Bool> {
		var result:Map<String, Bool> = [];
		var reverse:Map<String, Array<String>> = [], queue:Array<String> = [], queued:Map<String, Bool> = [], cursor = 0;
		for (name => fn in signatures) {
			var dependencies:Map<String, Bool> = [];
			collectDependencies(fn.statements, name, dependencies);
			for (dependency in dependencies.keys()) {
				var users = reverse.get(dependency);
				if (users == null) {
					users = [];
					reverse.set(dependency, users);
				}
				users.push(name);
			}
			queue.push(name);
			queued.set(name, true);
		}
		while (cursor < queue.length) {
			var name = queue[cursor++];
			queued.remove(name);
			var fn = signatures.get(name);
			if (fn == null || overridden.exists(name) || result.exists(name) || !astStatementsDoNotReturn(fn.statements, name, result))
				continue;
			result.set(name, true);
			var users = reverse.get(name);
			if (users != null)
				for (user in users)
					if (!queued.exists(user) && !result.exists(user)) {
						queued.set(user, true);
						queue.push(user);
					}
		}
		return result;
	}

	static function collectDependencies(statements:Array<AstStatement>, functionName:String, target:Map<String, Bool>):Void {
		for (statement in statements)
			switch statement {
				case Throw(_, _):
					return;
				case Expression(expression, _):
					switch expression {
						case Call(name, _, _): target.set(qualifiedLocalCall(name, functionName), true);
						default:
					}
					return;
				case If(_, yes, no, _):
					if (no.length > 0) {
						collectDependencies(yes, functionName, target);
						collectDependencies(no, functionName, target);
					}
					return;
				case Switch(_, cases, fallback, hasDefault, _):
					if (hasDefault) {
						collectDependencies(fallback, functionName, target);
						for (switchCase in cases)
							collectDependencies(switchCase.statements, functionName, target);
					}
					return;
				case VarDeclaration(_, _, _, _), UninitializedDeclaration(_, _, _), Assignment(_, _, _), IndexAssignment(_, _, _, _),
					FieldAssignment(_, _, _, _), Increment(_, _, _):
				default:
					return;
			}
	}

	static function astStatementsDoNotReturn(statements:Array<AstStatement>, functionName:String, noReturnFunctions:Map<String, Bool>):Bool {
		for (statement in statements)
			switch statement {
				case Throw(_, _):
					return true;
				case Expression(expression, _):
					switch expression {
						case Call(name, _, _): return noReturnFunctions.exists(qualifiedLocalCall(name, functionName));
						default: return false;
					}
				case If(_, yes, no, _)
					if (no.length > 0
						&& astStatementsDoNotReturn(yes, functionName, noReturnFunctions)
						&& astStatementsDoNotReturn(no, functionName, noReturnFunctions)):
					return true;
				case Switch(_, cases, fallback, hasDefault, _) if (hasDefault
					&& astStatementsDoNotReturn(fallback, functionName, noReturnFunctions)):
					var allExit = true;
					for (switchCase in cases)
						if (!astStatementsDoNotReturn(switchCase.statements, functionName, noReturnFunctions))
							allExit = false;
					if (allExit)
						return true;
					return false;
				case VarDeclaration(_, _, _, _), UninitializedDeclaration(_, _, _), Assignment(_, _, _), IndexAssignment(_, _, _, _),
					FieldAssignment(_, _, _, _), Increment(_, _, _):
					// Continue through statements which cannot transfer control.
				default:
					return false;
			}
		return false;
	}

	static function qualifiedLocalCall(name:String, functionName:String):String {
		if (name.indexOf(".") >= 0)
			return name;
		var cursor = functionName.length - 1;
		while (cursor >= 0) {
			if (functionName.charCodeAt(cursor) == 46)
				return functionName.substring(0, cursor) + "." + name;
			cursor--;
		}
		return name;
	}
}
