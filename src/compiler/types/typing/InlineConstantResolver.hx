package compiler.types.typing;

import compiler.core.Diagnostic;
import compiler.core.Diagnostic.CompileError;
import compiler.core.Source.SourceSpan;
import compiler.syntax.Ast.AstField;
import compiler.types.InlineConstantEvaluator;
import compiler.types.typing.InlineConstantState.ResolvedInlineConstant;

/** Resolves inline fields, detects cycles, and memoizes their typed constant values. */
class InlineConstantResolver {
	final session:TypingSession;
	final bodyTyper:BodyTyping;
	final dependencyCollectors:Array<Map<String, Bool>> = [];

	public function new(session:TypingSession, bodyTyper:BodyTyping) {
		this.session = session;
		this.bodyTyper = bodyTyper;
	}

	/** Every active initializer consumes nested constants, even when their values were already memoized. */
	public function recordDependency(target:String):Void {
		for (collector in dependencyCollectors)
			collector.set(target, true);
	}

	function recordResolved(key:String, resolved:ResolvedInlineConstant):Void {
		recordDependency(key);
		for (target in resolved.dependencies)
			recordDependency(target);
	}

	public function resolve(owner:String, name:String, span:SourceSpan):Null<ResolvedInlineConstant> {
		var classDecl = session.classDecls.get(owner);
		if (classDecl == null)
			return null;
		var field:Null<AstField> = null;
		for (candidate in classDecl.fields)
			if (candidate.isStatic && candidate.isInline && candidate.name == name) {
				field = candidate;
				break;
			}
		if (field == null || field.initializer == null)
			return null;
		var staticField = bodyTyper.findStaticFieldNullable(owner, name);
		if (staticField == null)
			return null;
		var key = staticField.owner + "." + name,
			cached = session.constants.inlineConstants.get(key);
		if (cached != null) {
			recordResolved(key, cached);
			return cached;
		}
		if (session.constants.inlineConstantsInProgress.exists(key))
			fail("E1002", 'Cyclic inline constant reference through "$key"', span);
		session.constants.inlineConstantsInProgress.set(key, true);
		var dependencies:Map<String, Bool> = [];
		dependencyCollectors.push(dependencies);
		var resolved:ResolvedInlineConstant;
		try {
			var initializer = bodyTyper.typeInlineInitializer(field.initializer, staticField.owner, name,
				staticField.type,
				classDecl.typeParameters),
				literal = InlineConstantEvaluator.evaluate(initializer);
			if (literal == null)
				fail("E1002", 'Inline field "${staticField.owner}.$name" requires a compile-time constant initializer',
					field.span);
			var targets = [for (target in dependencies.keys()) target];
			targets.sort(Reflect.compare);
			resolved = {
				dependencies: targets,
				initializer: initializer,
				value: bodyTyper.coerce(literal, staticField.type, 'inline field "${staticField.owner}.$name"', "E1002")
			};
		} catch (error:Dynamic) {
			dependencyCollectors.pop();
			session.constants.inlineConstantsInProgress.remove(key);
			throw error;
		}
		dependencyCollectors.pop();
		session.constants.inlineConstantsInProgress.remove(key);
		session.constants.inlineConstants.set(key, resolved);
		recordResolved(key, resolved);
		return resolved;
	}

	@:noReturn
	static function fail(code:String, message:String, span:SourceSpan):Void
		throw new CompileError(new Diagnostic(code, message, span));
}
