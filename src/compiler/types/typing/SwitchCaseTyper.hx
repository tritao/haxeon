package compiler.types.typing;

import compiler.core.Diagnostic;
import compiler.core.Diagnostic.CompileError;
import compiler.core.Source.SourceSpan;
import compiler.syntax.Ast.AstExpression;
import compiler.types.Type.CompilerType;
import compiler.types.TypedAst.TypedExpression;
import compiler.types.TypedAst.TypedSwitchArm;
import compiler.types.TypedAst.TypedSwitchArrayPattern;
import compiler.types.TypedAst.TypedSwitchBinding;
import compiler.types.TypedAst.TypedSwitchPredicate;
import compiler.types.analysis.Scope;

/** One pattern of a case, matched, before the case's guard is known (`SwitchCaseTyper.arm`). */
typedef SwitchPatternMatch = {
	final value:TypedExpression;
	final subjectBinding:Null<String>;
	final arrayPattern:Null<TypedSwitchArrayPattern>;
	final isCatchAll:Bool;
	final enumName:Null<String>;
	final constructorIndex:Int;
	final bindings:Array<TypedSwitchBinding>;
	final predicates:Array<TypedSwitchPredicate>;
	final span:SourceSpan;
}

private typedef PatternName = {name:String, type:CompilerType, span:SourceSpan};

/**
 * Types the patterns of one switch case, for statement and expression switches alike (docs/design/SWITCH_CASES.md). The first
 * pattern declares the case's bindings in the case's scope, where its guard and body are typed once. Every other pattern binds
 * the same names, with types assignable to the first's, as Haxe requires, and its bindings are the first's locals, so the
 * body reads them whichever pattern matched.
 */
class SwitchCaseTyper {
	final bodyTyper:BodyTyping;

	public function new(bodyTyper:BodyTyping)
		this.bodyTyper = bodyTyper;

	/**
	 * The patterns of a case, typed in order. `caseScope` gets the first pattern's bindings; `outer` is the switch's scope.
	 * `guarded` says whether the case has a guard: without one, a pattern another case already matched is a duplicate.
	 */
	public function typePatterns(patterns:Array<AstExpression>, caseSpan:SourceSpan, subject:TypedExpression,
			tupleTypes:Null<Array<CompilerType>>, constantType:Null<CompilerType>, outer:Scope, caseScope:Scope,
			guarded:Bool, seenCases:Map<String, Bool>):Array<SwitchPatternMatch> {
		var matches:Array<SwitchPatternMatch> = [], firstNames:Array<PatternName> = [];
		for (index in 0...patterns.length) {
			var scope = index == 0 ? caseScope : new Scope(outer),
				names:Array<PatternName> = [],
				saved = bodyTyper.patternNames;
			bodyTyper.patternNames = names;
			var match:SwitchPatternMatch;
			try
				match = typePattern(patterns[index], caseSpan, subject, tupleTypes, constantType, outer, scope)
			catch (error:haxe.Exception) {
				bodyTyper.patternNames = saved;
				throw error;
			}
			bodyTyper.patternNames = saved;
			if (index == 0)
				firstNames = names;
			else
				match = sharedBindings(match, names, firstNames, scope, caseScope);
			var caseKey = match.arrayPattern == null ? bodyTyper.switchCaseKey(match.value,
				match.predicates) : bodyTyper.switchArrayPatternKey(match.arrayPattern);
			if (match.isCatchAll)
				seenCases.set("$catchall", true);
			if (caseKey != null && !guarded) {
				if (seenCases.exists(caseKey))
					fail("E1020", "Duplicate switch case", caseSpan);
				seenCases.set(caseKey, true);
			}
			matches.push(match);
		}
		return matches;
	}

	/** The arm of `match` once the case's guard is typed; every pattern of a case has the same guard. */
	public static function arm(match:SwitchPatternMatch, guard:Null<TypedExpression>):TypedSwitchArm
		return {
			value: match.value,
			subjectBinding: match.subjectBinding,
			arrayPattern: match.arrayPattern,
			isCatchAll: match.isCatchAll,
			guard: guard,
			enumName: match.enumName,
			constructorIndex: match.constructorIndex,
			bindings: match.bindings,
			predicates: match.predicates,
			span: match.span
		};

	function typePattern(pattern:AstExpression, caseSpan:SourceSpan, subject:TypedExpression,
			tupleTypes:Null<Array<CompilerType>>, constantType:Null<CompilerType>, outer:Scope,
			scope:Scope):SwitchPatternMatch {
		var classified = tupleTypes == null ? bodyTyper.switchCasePattern(pattern, subject.type,
			scope) : bodyTyper.switchTuplePattern(pattern, tupleTypes, caseSpan, scope),
			enumPattern = classified.enumPattern,
			value = classified.isCatchAll
				|| classified.arrayPattern != null ? subject : enumPattern == null ? typeCaseConstant(classified.value,
				subject.type, constantType, outer) : enumPattern.value,
			enumName:Null<String> = enumPattern == null ? null : enumPattern.enumName,
			constructorIndex = enumPattern == null ? -1 : enumPattern.index;
		if (enumPattern == null) {
			var literal = BodyTyper.enumLiteral(value);
			if (literal != null) {
				enumName = literal.name;
				constructorIndex = literal.index;
			}
		}
		return {
			value: value,
			subjectBinding: classified.subjectBinding,
			arrayPattern: classified.arrayPattern,
			isCatchAll: classified.isCatchAll,
			enumName: enumName,
			constructorIndex: constructorIndex,
			bindings: enumPattern == null ? [] : enumPattern.bindings,
			predicates: enumPattern == null ? [] : enumPattern.predicates,
			span: caseSpan
		};
	}

	/** A constant case, typed as the subject's value: `case null` alone is typed as the (nullable) subject. */
	function typeCaseConstant(value:AstExpression, subjectType:CompilerType, constantType:Null<CompilerType>,
			scope:Scope):TypedExpression {
		var type = constantType == null
			|| compiler.syntax.AstPredicates.isNullExpression(value) ? subjectType : constantType;
		return bodyTyper.coerce(bodyTyper.typeExpression(value, scope, type), type, "switch case", "E1019");
	}

	/**
	 * `match`, a later pattern typed in `scope`, with its bindings made the first pattern's locals in `caseScope`, once its
	 * names are checked against the first's (`names` against `firstNames`).
	 */
	function sharedBindings(match:SwitchPatternMatch, names:Array<PatternName>, firstNames:Array<PatternName>,
			scope:Scope,
			caseScope:Scope):SwitchPatternMatch {
		var locals:Map<String, String> = [];
		for (bound in names) {
			var first = named(firstNames, bound.name);
			if (first == null)
				fail("E1019", 'Variable ${bound.name} must appear exactly once in each sub-pattern', bound.span);
			else if (!bodyTyper.isAssignableTo(bound.type, first.type))
				// Reported at the first pattern's binding, as Haxe does.
				fail("E1003",
					'${compiler.semantic.SemanticSignature.display(bound.type)} should be ${compiler.semantic.SemanticSignature.display(first.type)}',
					first.span);
			locals.set(scope.requireId(bound.name), caseScope.requireId(bound.name));
		}
		for (first in firstNames)
			if (named(names, first.name) == null)
				fail("E1019", 'Variable ${first.name} must appear exactly once in each sub-pattern', first.span);
		function local(id:Null<String>):Null<String>
			return id == null ? null : locals.exists(id) ? locals.get(id) : id;
		function bindings(list:Array<TypedSwitchBinding>):Array<TypedSwitchBinding>
			return [for (binding in list)
				{
					name:local(binding.name),
						type:binding.type,
						storageType:binding.storageType,
						fieldStorageType:binding.fieldStorageType,
						index:binding.index,
						arrayIndex:binding.arrayIndex,
						nestedPath:binding.nestedPath
				}];
		var arrayPattern = match.arrayPattern;
		return {value: match.value,
			subjectBinding: local(match.subjectBinding),
			arrayPattern: arrayPattern == null ? null : {elements: [for (element in arrayPattern.elements)
			{
				type:element.type,
					value:element.value,
					equalityFunction:element.equalityFunction,
					subjectBinding:local(element.subjectBinding),
					isCatchAll:element.isCatchAll,
					constructorIndex:element.constructorIndex,
					bindings:bindings(element.bindings),
					predicates:element.predicates
			}]},
				isCatchAll: match.isCatchAll,
				enumName: match.enumName,
				constructorIndex: match.constructorIndex,
				bindings: bindings(match.bindings),
				predicates: match.predicates,
				span: match.span};
	}

	static function named(names:Array<PatternName>, name:String):Null<PatternName> {
		for (bound in names)
			if (bound.name == name)
				return bound;
		return null;
	}

	static function fail(code:String, message:String, span:SourceSpan):Void
		throw new CompileError(new Diagnostic(code, message, span));
}
