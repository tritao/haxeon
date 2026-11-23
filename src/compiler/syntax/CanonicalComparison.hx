package compiler.syntax;

import compiler.core.Source.SourceSpan;
import compiler.syntax.Ast;

/** How positions count when two canonical forms are compared (`CanonicalComparison`). */
enum abstract PositionsCount(Int) {
	/** Not at all: a reader sees the structure and the names, not where they are. */
	var Ignored = 0;

	/** By file and line: debug metadata names lines, so code copied or inlined into a reader carries them. */
	var Lines = 1;

	/** By offset: a generic function's specializations name their lambdas and debug mappings by offset. */
	var Offsets = 2;
}

/**
 * Whether two canonical forms of a declaration, or of a part of one, mean the same to a reader: the same syntax with the same
 * names resolved, and the same positions as a `PositionsCount` counts them. `skipped` names the parts of the syntax objects a
 * comparison leaves out (`statements`, `initializer`, `values`, `fields`, `methods`, `defaultValue`), which are facts of their
 * own. Every kind of node is matched by name, so a kind added to `Ast` does not compile here until it is compared.
 */
class CanonicalComparison {
	final positions:PositionsCount;
	final skippedParts:Null<Array<String>>;

	function new(positions:PositionsCount, skipped:Null<Array<String>>) {
		this.positions = positions;
		skippedParts = skipped;
	}

	function skips(part:String):Bool {
		var parts = skippedParts;
		return parts != null && parts.indexOf(part) >= 0;
	}

	public static function functions(left:AstFunction, right:AstFunction, positions:PositionsCount,
			?skipped:Array<String>):Bool
		return new CanonicalComparison(positions, skipped).astFunction(left, right);

	public static function functionList(left:Array<AstFunction>, right:Array<AstFunction>, positions:PositionsCount,
			?skipped:Array<String>):Bool {
		var comparison = new CanonicalComparison(positions, skipped);
		return comparison.array(left, right, comparison.astFunction);
	}

	public static function statements(left:Array<AstStatement>, right:Array<AstStatement>,
			positions:PositionsCount):Bool {
		var comparison = new CanonicalComparison(positions, null);
		return comparison.array(left, right, comparison.astStatement);
	}

	public static function expressions(left:Array<Null<AstExpression>>, right:Array<Null<AstExpression>>,
			positions:PositionsCount):Bool {
		if (left.length != right.length)
			return false;
		var comparison = new CanonicalComparison(positions, null);
		for (index in 0...left.length)
			if (!comparison.optional(left[index], right[index], comparison.astExpression))
				return false;
		return true;
	}

	public static function expression(left:Null<AstExpression>, right:Null<AstExpression>,
			positions:PositionsCount):Bool {
		var comparison = new CanonicalComparison(positions, null);
		return comparison.optional(left, right, comparison.astExpression);
	}

	public static function classes(left:AstClass, right:AstClass, positions:PositionsCount, ?skipped:Array<String>):Bool
		return new CanonicalComparison(positions, skipped).astClass(left, right);

	public static function fieldList(left:Array<AstField>, right:Array<AstField>, positions:PositionsCount,
			?skipped:Array<String>):Bool {
		var comparison = new CanonicalComparison(positions, skipped);
		return comparison.array(left, right, comparison.astField);
	}

	public static function enums(left:AstEnum, right:AstEnum, positions:PositionsCount, ?skipped:Array<String>):Bool
		return new CanonicalComparison(positions, skipped).astEnum(left, right);

	public static function enumCases(left:AstEnumCase, right:AstEnumCase, positions:PositionsCount):Bool
		return new CanonicalComparison(positions, null).astEnumCase(left, right);

	public static function abstracts(left:AstAbstract, right:AstAbstract, positions:PositionsCount,
			?skipped:Array<String>):Bool
		return new CanonicalComparison(positions, skipped).astAbstract(left, right);

	public static function abstractValues(left:Null<Array<AstEnumAbstractValue>>,
			right:Null<Array<AstEnumAbstractValue>>,
			positions:PositionsCount):Bool {
		var comparison = new CanonicalComparison(positions, null);
		return comparison.optionalArray(left, right, comparison.astEnumAbstractValue);
	}

	public static function interfaces(left:AstInterface, right:AstInterface, positions:PositionsCount,
			?skipped:Array<String>):Bool
		return new CanonicalComparison(positions, skipped).astInterface(left, right);

	public static function aliases(left:AstTypeAlias, right:AstTypeAlias, positions:PositionsCount):Bool
		return new CanonicalComparison(positions, null).astTypeAlias(left, right);

	function span(left:SourceSpan, right:SourceSpan):Bool {
		if (left.isBareReference != right.isBareReference || left.referenceName != right.referenceName
			|| left.generatedReason != right.generatedReason)
			return false;
		return switch positions {
			case Ignored: true;
			case Lines: left.file.path == right.file.path && line(left) == line(right);
			case Offsets: left.file.path == right.file.path && left.start == right.start && left.end == right.end;
		};
	}

	static function line(span:SourceSpan):Int
		return span.file.text.length == 0 ? 0 : span.file.lineAt(span.start);

	function temporary(left:TemporaryLocal, right:TemporaryLocal):Bool
		return left.name == right.name;

	function array<T>(left:Array<T>, right:Array<T>, same:(T, T) -> Bool):Bool {
		if (left.length != right.length)
			return false;
		for (index in 0...left.length)
			if (!same(left[index], right[index]))
				return false;
		return true;
	}

	function optional<T>(left:Null<T>, right:Null<T>, same:(T, T) -> Bool):Bool {
		if (left == null || right == null)
			return left == null && right == null;
		return same(left, right);
	}

	function optionalArray<T>(left:Null<Array<T>>, right:Null<Array<T>>, same:(T, T) -> Bool):Bool {
		if (left == null || right == null)
			return left == null && right == null;
		return array(left, right, same);
	}

	static function sameValues<T>(left:Array<T>, right:Array<T>):Bool {
		if (left.length != right.length)
			return false;
		for (index in 0...left.length)
			if (left[index] != right[index])
				return false;
		return true;
	}

	static function optionalValues<T>(left:Null<Array<T>>, right:Null<Array<T>>):Bool {
		if (left == null || right == null)
			return left == null && right == null;
		return sameValues(left, right);
	}

	function astType(left:AstType, right:AstType):Bool
		return switch left {
			case IntType: switch right {
					case IntType: true;
					default: false;
				};
			case BoolType: switch right {
					case BoolType: true;
					default: false;
				};
			case FloatType: switch right {
					case FloatType: true;
					default: false;
				};
			case StringType: switch right {
					case StringType: true;
					default: false;
				};
			case VoidType: switch right {
					case VoidType: true;
					default: false;
				};
			case InferredType: switch right {
					case InferredType: true;
					default: false;
				};
			case ErrorType(l0): switch right {
					case ErrorType(r0): span(l0, r0);
					default: false;
				};
			case NativeAbstractType(l0, l1): switch right {
					case NativeAbstractType(r0, r1): l0 == r0
						&& l1 == r1;
					default: false;
				};
			case NamedType(l0): switch right {
					case NamedType(r0): l0 == r0;
					default: false;
				};
			case AppliedType(l0, l1): switch right {
					case AppliedType(r0, r1): l0 == r0
						&& array(l1, r1, astType);
					default: false;
				};
			case ArrayType(l0): switch right {
					case ArrayType(r0): astType(l0, r0);
					default: false;
				};
			case MapType(l0, l1): switch right {
					case MapType(r0, r1): astType(l0, r0)
						&& astType(l1, r1);
					default: false;
				};
			case NullableType(l0): switch right {
					case NullableType(r0): astType(l0, r0);
					default: false;
				};
			case FunctionType(l0, l1, l2): switch right {
					case FunctionType(r0, r1, r2): array(l0, r0, astType)
						&& astType(l1, r1)
						&& sameValues(l2, r2);
					default: false;
				};
			case AnonymousType(l0): switch right {
					case AnonymousType(r0): array(l0, r0, astAnonymousField);
					default: false;
				};
		};

	function astExpression(left:AstExpression, right:AstExpression):Bool
		return switch left {
			case AnnotatedExpression(l0, l1, l2): switch right {
					case AnnotatedExpression(r0, r1, r2): scopeMetadata(l0, r0)
						&& astExpression(l1, r1)
						&& span(l2, r2);
					default: false;
				};
			case IntegerLiteral(l0, l1): switch right {
					case IntegerLiteral(r0, r1): l0 == r0
						&& span(l1, r1);
					default: false;
				};
			case FloatLiteral(l0, l1): switch right {
					case FloatLiteral(r0, r1): l0 == r0
						&& span(l1, r1);
					default: false;
				};
			case StringLiteral(l0, l1): switch right {
					case StringLiteral(r0, r1): l0 == r0
						&& span(l1, r1);
					default: false;
				};
			case BoolLiteral(l0, l1): switch right {
					case BoolLiteral(r0, r1): l0 == r0
						&& span(l1, r1);
					default: false;
				};
			case NullLiteral(l0): switch right {
					case NullLiteral(r0): span(l0, r0);
					default: false;
				};
			case Unreachable(l0): switch right {
					case Unreachable(r0): span(l0, r0);
					default: false;
				};
			case EmptyExpression(l0): switch right {
					case EmptyExpression(r0): span(l0, r0);
					default: false;
				};
			case ErrorExpression(l0): switch right {
					case ErrorExpression(r0): span(l0, r0);
					default: false;
				};
			case Variable(l0, l1): switch right {
					case Variable(r0, r1): l0 == r0
						&& span(l1, r1);
					default: false;
				};
			case TemporaryVariable(l0, l1): switch right {
					case TemporaryVariable(r0, r1): temporary(l0, r0)
						&& span(l1, r1);
					default: false;
				};
			case DeclaredVariable(l0, l1, l2): switch right {
					case DeclaredVariable(r0, r1, r2): l0 == r0
						&& l1 == r1
						&& span(l2, r2);
					default: false;
				};
			case Member(l0, l1, l2): switch right {
					case Member(r0, r1, r2): astExpression(l0, r0)
						&& l1 == r1
						&& span(l2, r2);
					default: false;
				};
			case Add(l0, l1, l2): switch right {
					case Add(r0, r1, r2): astExpression(l0, r0)
						&& astExpression(l1, r1)
						&& span(l2, r2);
					default: false;
				};
			case Sub(l0, l1, l2): switch right {
					case Sub(r0, r1, r2): astExpression(l0, r0)
						&& astExpression(l1, r1)
						&& span(l2, r2);
					default: false;
				};
			case Mul(l0, l1, l2): switch right {
					case Mul(r0, r1, r2): astExpression(l0, r0)
						&& astExpression(l1, r1)
						&& span(l2, r2);
					default: false;
				};
			case Div(l0, l1, l2): switch right {
					case Div(r0, r1, r2): astExpression(l0, r0)
						&& astExpression(l1, r1)
						&& span(l2, r2);
					default: false;
				};
			case Mod(l0, l1, l2): switch right {
					case Mod(r0, r1, r2): astExpression(l0, r0)
						&& astExpression(l1, r1)
						&& span(l2, r2);
					default: false;
				};
			case BitAnd(l0, l1, l2): switch right {
					case BitAnd(r0, r1, r2): astExpression(l0, r0)
						&& astExpression(l1, r1)
						&& span(l2, r2);
					default: false;
				};
			case BitXor(l0, l1, l2): switch right {
					case BitXor(r0, r1, r2): astExpression(l0, r0)
						&& astExpression(l1, r1)
						&& span(l2, r2);
					default: false;
				};
			case BitOr(l0, l1, l2): switch right {
					case BitOr(r0, r1, r2): astExpression(l0, r0)
						&& astExpression(l1, r1)
						&& span(l2, r2);
					default: false;
				};
			case ShiftLeft(l0, l1, l2): switch right {
					case ShiftLeft(r0, r1, r2): astExpression(l0, r0)
						&& astExpression(l1, r1)
						&& span(l2, r2);
					default: false;
				};
			case ShiftRight(l0, l1, l2): switch right {
					case ShiftRight(r0, r1, r2): astExpression(l0, r0)
						&& astExpression(l1, r1)
						&& span(l2, r2);
					default: false;
				};
			case UnsignedShiftRight(l0, l1, l2): switch right {
					case UnsignedShiftRight(r0, r1, r2): astExpression(l0, r0)
						&& astExpression(l1, r1)
						&& span(l2, r2);
					default: false;
				};
			case Negate(l0, l1): switch right {
					case Negate(r0, r1): astExpression(l0, r0)
						&& span(l1, r1);
					default: false;
				};
			case Less(l0, l1, l2): switch right {
					case Less(r0, r1, r2): astExpression(l0, r0)
						&& astExpression(l1, r1)
						&& span(l2, r2);
					default: false;
				};
			case LessEqual(l0, l1, l2): switch right {
					case LessEqual(r0, r1, r2): astExpression(l0, r0)
						&& astExpression(l1, r1)
						&& span(l2, r2);
					default: false;
				};
			case Greater(l0, l1, l2): switch right {
					case Greater(r0, r1, r2): astExpression(l0, r0)
						&& astExpression(l1, r1)
						&& span(l2, r2);
					default: false;
				};
			case GreaterEqual(l0, l1, l2): switch right {
					case GreaterEqual(r0, r1, r2): astExpression(l0, r0)
						&& astExpression(l1, r1)
						&& span(l2, r2);
					default: false;
				};
			case Equal(l0, l1, l2): switch right {
					case Equal(r0, r1, r2): astExpression(l0, r0)
						&& astExpression(l1, r1)
						&& span(l2, r2);
					default: false;
				};
			case NotEqual(l0, l1, l2): switch right {
					case NotEqual(r0, r1, r2): astExpression(l0, r0)
						&& astExpression(l1, r1)
						&& span(l2, r2);
					default: false;
				};
			case Not(l0, l1): switch right {
					case Not(r0, r1): astExpression(l0, r0)
						&& span(l1, r1);
					default: false;
				};
			case And(l0, l1, l2): switch right {
					case And(r0, r1, r2): astExpression(l0, r0)
						&& astExpression(l1, r1)
						&& span(l2, r2);
					default: false;
				};
			case Or(l0, l1, l2): switch right {
					case Or(r0, r1, r2): astExpression(l0, r0)
						&& astExpression(l1, r1)
						&& span(l2, r2);
					default: false;
				};
			case Conditional(l0, l1, l2, l3): switch right {
					case Conditional(r0, r1, r2, r3): astExpression(l0, r0)
						&& astExpression(l1, r1)
						&& astExpression(l2, r2)
						&& span(l3, r3);
					default: false;
				};
			case BlockExpression(l0, l1, l2): switch right {
					case BlockExpression(r0, r1, r2): array(l0, r0, astStatement)
						&& astExpression(l1, r1)
						&& span(l2, r2);
					default: false;
				};
			case Capture(l0, l1, l2): switch right {
					case Capture(r0, r1, r2): l0 == r0
						&& astExpression(l1, r1)
						&& span(l2, r2);
					default: false;
				};
			case Extractor(l0, l1, l2): switch right {
					case Extractor(r0, r1, r2): astExpression(l0, r0)
						&& astExpression(l1, r1)
						&& span(l2, r2);
					default: false;
				};
			case Spread(l0, l1): switch right {
					case Spread(r0, r1): astExpression(l0, r0)
						&& span(l1, r1);
					default: false;
				};
			case ThrowExpression(l0, l1): switch right {
					case ThrowExpression(r0, r1): astExpression(l0, r0)
						&& span(l1, r1);
					default: false;
				};
			case Cast(l0, l1, l2): switch right {
					case Cast(r0, r1, r2): astExpression(l0, r0)
						&& optional(l1, r1, astType)
						&& span(l2, r2);
					default: false;
				};
			case CheckType(l0, l1, l2): switch right {
					case CheckType(r0, r1, r2): astExpression(l0, r0)
						&& astType(l1, r1)
						&& span(l2, r2);
					default: false;
				};
			case SwitchExpression(l0, l1, l2, l3): switch right {
					case SwitchExpression(r0, r1, r2, r3): astExpression(l0, r0)
						&& array(l1, r1, astSwitchExpressionCase)
						&& optional(l2, r2, astExpression)
						&& span(l3, r3);
					default: false;
				};
			case ObjectLiteral(l0, l1): switch right {
					case ObjectLiteral(r0, r1): array(l0, r0, astObjectField)
						&& span(l1, r1);
					default: false;
				};
			case ArrayLiteral(l0, l1): switch right {
					case ArrayLiteral(r0, r1): array(l0, r0, astExpression)
						&& span(l1, r1);
					default: false;
				};
			case MapLiteral(l0, l1): switch right {
					case MapLiteral(r0, r1): array(l0, r0, astMapEntry)
						&& span(l1, r1);
					default: false;
				};
			case ArrayComprehension(l0, l1, l2, l3, l4, l5, l6): switch right {
					case ArrayComprehension(r0, r1, r2, r3, r4, r5, r6): l0 == r0
						&& l1 == r1
						&& astExpression(l2, r2)
						&& optional(l3, r3, astExpression)
						&& astExpression(l4, r4)
						&& l5 == r5
						&& span(l6, r6);
					default: false;
				};
			case MapComprehension(l0, l1, l2, l3, l4, l5, l6): switch right {
					case MapComprehension(r0, r1, r2, r3, r4, r5, r6): l0 == r0
						&& l1 == r1
						&& astExpression(l2, r2)
						&& optional(l3, r3, astExpression)
						&& astExpression(l4, r4)
						&& astExpression(l5, r5)
						&& span(l6, r6);
					default: false;
				};
			case Range(l0, l1, l2): switch right {
					case Range(r0, r1, r2): astExpression(l0, r0)
						&& astExpression(l1, r1)
						&& span(l2, r2);
					default: false;
				};
			case Call(l0, l1, l2): switch right {
					case Call(r0, r1, r2): l0 == r0
						&& array(l1, r1, astExpression)
						&& span(l2, r2);
					default: false;
				};
			case NativeLayoutQuery(l0, l1, l2, l3): switch right {
					case NativeLayoutQuery(r0, r1, r2, r3): nativeLayoutQueryKind(l0, r0)
						&& astType(l1, r1)
						&& l2 == r2
						&& span(l3, r3);
					default: false;
				};
			case KeyPathLiteral(l0, l1, l2): switch right {
					case KeyPathLiteral(r0, r1, r2): astType(l0, r0)
						&& sameValues(l1, r1)
						&& span(l2, r2);
					default: false;
				};
			case ClosureCall(l0, l1, l2): switch right {
					case ClosureCall(r0, r1, r2): astExpression(l0, r0)
						&& array(l1, r1, astExpression)
						&& span(l2, r2);
					default: false;
				};
			case MethodCall(l0, l1, l2, l3): switch right {
					case MethodCall(r0, r1, r2, r3): astExpression(l0, r0)
						&& l1 == r1
						&& array(l2, r2, astExpression)
						&& span(l3, r3);
					default: false;
				};
			case New(l0, l1, l2): switch right {
					case New(r0, r1, r2): l0 == r0
						&& array(l1, r1, astExpression)
						&& span(l2, r2);
					default: false;
				};
			case NewGeneric(l0, l1, l2, l3): switch right {
					case NewGeneric(r0, r1, r2, r3): l0 == r0
						&& array(l1, r1, astType)
						&& array(l2, r2, astExpression)
						&& span(l3, r3);
					default: false;
				};
			case NewArray(l0, l1, l2): switch right {
					case NewArray(r0, r1, r2): astType(l0, r0)
						&& astExpression(l1, r1)
						&& span(l2, r2);
					default: false;
				};
			case NewMap(l0, l1, l2): switch right {
					case NewMap(r0, r1, r2): astType(l0, r0)
						&& astType(l1, r1)
						&& span(l2, r2);
					default: false;
				};
			case Index(l0, l1, l2): switch right {
					case Index(r0, r1, r2): astExpression(l0, r0)
						&& astExpression(l1, r1)
						&& span(l2, r2);
					default: false;
				};
			case PostfixIncrement(l0, l1, l2): switch right {
					case PostfixIncrement(r0, r1, r2): astExpression(l0, r0)
						&& l1 == r1
						&& span(l2, r2);
					default: false;
				};
			case AssignmentValue(l0, l1): switch right {
					case AssignmentValue(r0, r1): astStatement(l0, r0)
						&& span(l1, r1);
					default: false;
				};
			case Lambda(l0, l1, l2, l3, l4, l5): switch right {
					case Lambda(r0, r1, r2, r3, r4, r5): array(l0, r0, astArgument)
						&& array(l1, r1, astStatement)
						&& l2 == r2
						&& span(l3, r3)
						&& l4 == r4
						&& l5 == r5;
					default: false;
				};
		};

	function astStatement(left:AstStatement, right:AstStatement):Bool
		return switch left {
			case AnnotatedStatement(l0, l1, l2): switch right {
					case AnnotatedStatement(r0, r1, r2): scopeMetadata(l0, r0)
						&& astStatement(l1, r1)
						&& span(l2, r2);
					default: false;
				};
			case ErrorStatement(l0): switch right {
					case ErrorStatement(r0): span(l0, r0);
					default: false;
				};
			case UninitializedDeclaration(l0, l1, l2): switch right {
					case UninitializedDeclaration(r0, r1, r2): l0 == r0
						&& astType(l1, r1)
						&& span(l2, r2);
					default: false;
				};
			case VarDeclaration(l0, l1, l2, l3): switch right {
					case VarDeclaration(r0, r1, r2, r3): l0 == r0
						&& optional(l1, r1, astType)
						&& astExpression(l2, r2)
						&& span(l3, r3);
					default: false;
				};
			case ScopedDeclaration(l0, l1, l2, l3): switch right {
					case ScopedDeclaration(r0, r1, r2, r3): l0 == r0
						&& optional(l1, r1, astType)
						&& astExpression(l2, r2)
						&& span(l3, r3);
					default: false;
				};
			case Assignment(l0, l1, l2): switch right {
					case Assignment(r0, r1, r2): l0 == r0
						&& astExpression(l1, r1)
						&& span(l2, r2);
					default: false;
				};
			case TemporaryDeclaration(l0, l1, l2, l3): switch right {
					case TemporaryDeclaration(r0, r1, r2, r3): temporary(l0, r0)
						&& optional(l1, r1, astType)
						&& astExpression(l2, r2)
						&& span(l3, r3);
					default: false;
				};
			case TemporaryAssignment(l0, l1, l2): switch right {
					case TemporaryAssignment(r0, r1, r2): temporary(l0, r0)
						&& astExpression(l1, r1)
						&& span(l2, r2);
					default: false;
				};
			case DeclaredAssignment(l0, l1, l2, l3): switch right {
					case DeclaredAssignment(r0, r1, r2, r3): l0 == r0
						&& l1 == r1
						&& astExpression(l2, r2)
						&& span(l3, r3);
					default: false;
				};
			case IndexAssignment(l0, l1, l2, l3): switch right {
					case IndexAssignment(r0, r1, r2, r3): astExpression(l0, r0)
						&& astExpression(l1, r1)
						&& astExpression(l2, r2)
						&& span(l3, r3);
					default: false;
				};
			case FieldAssignment(l0, l1, l2, l3): switch right {
					case FieldAssignment(r0, r1, r2, r3): astExpression(l0, r0)
						&& l1 == r1
						&& astExpression(l2, r2)
						&& span(l3, r3);
					default: false;
				};
			case Return(l0, l1): switch right {
					case Return(r0, r1): astExpression(l0, r0)
						&& span(l1, r1);
					default: false;
				};
			case ReturnVoid(l0): switch right {
					case ReturnVoid(r0): span(l0, r0);
					default: false;
				};
			case Throw(l0, l1): switch right {
					case Throw(r0, r1): astExpression(l0, r0)
						&& span(l1, r1);
					default: false;
				};
			case Defer(l0, l1): switch right {
					case Defer(r0, r1): array(l0, r0, astStatement)
						&& span(l1, r1);
					default: false;
				};
			case Try(l0, l1, l2): switch right {
					case Try(r0, r1, r2): array(l0, r0, astStatement)
						&& array(l1, r1, astCatch)
						&& span(l2, r2);
					default: false;
				};
			case If(l0, l1, l2, l3): switch right {
					case If(r0, r1, r2, r3): astExpression(l0, r0)
						&& array(l1, r1, astStatement)
						&& array(l2, r2, astStatement)
						&& span(l3, r3);
					default: false;
				};
			case While(l0, l1, l2): switch right {
					case While(r0, r1, r2): astExpression(l0, r0)
						&& array(l1, r1, astStatement)
						&& span(l2, r2);
					default: false;
				};
			case DoWhile(l0, l1, l2): switch right {
					case DoWhile(r0, r1, r2): array(l0, r0, astStatement)
						&& astExpression(l1, r1)
						&& span(l2, r2);
					default: false;
				};
			case ForIn(l0, l1, l2, l3, l4): switch right {
					case ForIn(r0, r1, r2, r3, r4): l0 == r0
						&& l1 == r1
						&& astExpression(l2, r2)
						&& array(l3, r3, astStatement)
						&& span(l4, r4);
					default: false;
				};
			case Break(l0): switch right {
					case Break(r0): span(l0, r0);
					default: false;
				};
			case Continue(l0): switch right {
					case Continue(r0): span(l0, r0);
					default: false;
				};
			case Switch(l0, l1, l2, l3, l4): switch right {
					case Switch(r0, r1, r2, r3, r4): astExpression(l0, r0)
						&& array(l1, r1, astSwitchCase)
						&& array(l2, r2, astStatement)
						&& l3 == r3
						&& span(l4, r4);
					default: false;
				};
			case Increment(l0, l1, l2): switch right {
					case Increment(r0, r1, r2): l0 == r0
						&& l1 == r1
						&& span(l2, r2);
					default: false;
				};
			case Expression(l0, l1): switch right {
					case Expression(r0, r1): astExpression(l0, r0)
						&& span(l1, r1);
					default: false;
				};
		};

	function scopeMetadata(left:ScopeMetadata, right:ScopeMetadata):Bool
		return switch left {
			case PrivateAccess: switch right {
					case PrivateAccess: true;
					default: false;
				};
			case NullSafetyOff: switch right {
					case NullSafetyOff: true;
					default: false;
				};
		};

	function nativeLayoutQueryKind(left:NativeLayoutQueryKind, right:NativeLayoutQueryKind):Bool
		return switch left {
			case SizeOf: switch right {
					case SizeOf: true;
					default: false;
				};
			case AlignOf: switch right {
					case AlignOf: true;
					default: false;
				};
			case OffsetOf: switch right {
					case OffsetOf: true;
					default: false;
				};
			case TypeInfo: switch right {
					case TypeInfo: true;
					default: false;
				};
		};

	function astFieldAccess(left:AstFieldAccess, right:AstFieldAccess):Bool
		return switch left {
			case DefaultAccess: switch right {
					case DefaultAccess: true;
					default: false;
				};
			case NullAccess: switch right {
					case NullAccess: true;
					default: false;
				};
			case NeverAccess: switch right {
					case NeverAccess: true;
					default: false;
				};
			case GetAccess: switch right {
					case GetAccess: true;
					default: false;
				};
			case SetAccess: switch right {
					case SetAccess: true;
					default: false;
				};
			case DynamicAccess: switch right {
					case DynamicAccess: true;
					default: false;
				};
		};

	function astAnonymousField(left:AstAnonymousField, right:AstAnonymousField):Bool {
		if (!(left.name == right.name))
			return false;
		if (!(astType(left.type, right.type)))
			return false;
		if (!(left.optional == right.optional))
			return false;
		if (!(left.isFinal == right.isFinal))
			return false;
		if (!(array(left.metadata, right.metadata, astMetadata)))
			return false;
		if (!(span(left.span, right.span)))
			return false;
		return true;
	}

	function astArgument(left:AstArgument, right:AstArgument):Bool {
		if (!(left.name == right.name))
			return false;
		if (!(astType(left.type, right.type)))
			return false;
		if (!(span(left.span, right.span)))
			return false;
		if (!(left.optional == right.optional))
			return false;
		if (!skips("defaultValue") && !(optional(left.defaultValue, right.defaultValue, astExpression)))
			return false;
		if (!(optional(left.local, right.local, temporary)))
			return false;
		return true;
	}

	function astField(left:AstField, right:AstField):Bool {
		if (!(left.name == right.name))
			return false;
		if (!(left.isPublic == right.isPublic))
			return false;
		if (!(array(left.metadata, right.metadata, astMetadata)))
			return false;
		if (!(optional(left.type, right.type, astType)))
			return false;
		if (!skips("initializer") && !(optional(left.initializer, right.initializer, astExpression)))
			return false;
		if (!(optional(left.readAccess, right.readAccess, astFieldAccess)))
			return false;
		if (!(optional(left.writeAccess, right.writeAccess, astFieldAccess)))
			return false;
		if (!(left.isStatic == right.isStatic))
			return false;
		if (!(left.isInline == right.isInline))
			return false;
		if (!(left.isFinal == right.isFinal))
			return false;
		if (!(span(left.span, right.span)))
			return false;
		if (!(optional(left.declarationSpan, right.declarationSpan, span)))
			return false;
		return true;
	}

	function astClass(left:AstClass, right:AstClass):Bool {
		if (!(left.name == right.name))
			return false;
		if (!(left.isStruct == right.isStruct))
			return false;
		if (!(left.isExtern == right.isExtern))
			return false;
		if (!(sameValues(left.typeParameters, right.typeParameters)))
			return false;
		if (!(optionalArray(left.typeConstraints, right.typeConstraints, astTypeConstraint)))
			return false;
		if (!(left.isPrivate == right.isPrivate))
			return false;
		if (!(array(left.metadata, right.metadata, astMetadata)))
			return false;
		if (!(optional(left.base, right.base, astType)))
			return false;
		if (!(array(left.interfaces, right.interfaces, astType)))
			return false;
		if (!skips("fields") && !(array(left.fields, right.fields, astField)))
			return false;
		if (!skips("methods") && !(array(left.methods, right.methods, astFunction)))
			return false;
		if (!(span(left.span, right.span)))
			return false;
		return true;
	}

	function astMetadata(left:AstMetadata, right:AstMetadata):Bool {
		if (!(left.name == right.name))
			return false;
		if (!(array(left.arguments, right.arguments, astExpression)))
			return false;
		if (!(span(left.span, right.span)))
			return false;
		return true;
	}

	function astInterface(left:AstInterface, right:AstInterface):Bool {
		if (!(left.name == right.name))
			return false;
		if (!(sameValues(left.typeParameters, right.typeParameters)))
			return false;
		if (!(optionalArray(left.typeConstraints, right.typeConstraints, astTypeConstraint)))
			return false;
		if (!(array(left.bases, right.bases, astType)))
			return false;
		if (!skips("fields") && !(array(left.fields, right.fields, astField)))
			return false;
		if (!skips("methods") && !(array(left.methods, right.methods, astFunction)))
			return false;
		if (!(span(left.span, right.span)))
			return false;
		return true;
	}

	function astTypeAlias(left:AstTypeAlias, right:AstTypeAlias):Bool {
		if (!(left.name == right.name))
			return false;
		if (!(array(left.metadata, right.metadata, astMetadata)))
			return false;
		if (!(sameValues(left.typeParameters, right.typeParameters)))
			return false;
		if (!(optionalArray(left.typeConstraints, right.typeConstraints, astTypeConstraint)))
			return false;
		if (!(astType(left.type, right.type)))
			return false;
		if (!(left.isPrivate == right.isPrivate))
			return false;
		if (!(span(left.span, right.span)))
			return false;
		return true;
	}

	function astEnumParameter(left:AstEnumParameter, right:AstEnumParameter):Bool {
		if (!(left.name == right.name))
			return false;
		if (!(astType(left.type, right.type)))
			return false;
		if (!(left.optional == right.optional))
			return false;
		if (!(span(left.span, right.span)))
			return false;
		return true;
	}

	function astEnumCase(left:AstEnumCase, right:AstEnumCase):Bool {
		if (!(left.name == right.name))
			return false;
		if (!(array(left.metadata, right.metadata, astMetadata)))
			return false;
		if (!(array(left.params, right.params, astEnumParameter)))
			return false;
		if (!(span(left.span, right.span)))
			return false;
		return true;
	}

	function astEnum(left:AstEnum, right:AstEnum):Bool {
		if (!(left.name == right.name))
			return false;
		if (!(sameValues(left.typeParameters, right.typeParameters)))
			return false;
		if (!(optionalArray(left.typeConstraints, right.typeConstraints, astTypeConstraint)))
			return false;
		if (!(optionalArray(left.conformances, right.conformances, astType)))
			return false;
		if (!skips("methods") && !(optionalArray(left.methods, right.methods, astFunction)))
			return false;
		if (!(array(left.metadata, right.metadata, astMetadata)))
			return false;
		if (!skips("cases") && !(array(left.cases, right.cases, astEnumCase)))
			return false;
		if (!(span(left.span, right.span)))
			return false;
		return true;
	}

	function astEnumAbstractValue(left:AstEnumAbstractValue, right:AstEnumAbstractValue):Bool {
		if (!(left.name == right.name))
			return false;
		if (!(array(left.metadata, right.metadata, astMetadata)))
			return false;
		if (!(astExpression(left.value, right.value)))
			return false;
		if (!(span(left.span, right.span)))
			return false;
		return true;
	}

	function astAbstract(left:AstAbstract, right:AstAbstract):Bool {
		if (!(left.name == right.name))
			return false;
		if (!(left.isExtern == right.isExtern))
			return false;
		if (!(optionalArray(left.metadata, right.metadata, astMetadata)))
			return false;
		if (!(sameValues(left.typeParameters, right.typeParameters)))
			return false;
		if (!(optionalArray(left.typeConstraints, right.typeConstraints, astTypeConstraint)))
			return false;
		if (!(optionalArray(left.conformances, right.conformances, astType)))
			return false;
		if (!(astType(left.underlying, right.underlying)))
			return false;
		if (!(array(left.fromTypes, right.fromTypes, astType)))
			return false;
		if (!(array(left.toTypes, right.toTypes, astType)))
			return false;
		if (!skips("fields") && !(array(left.fields, right.fields, astField)))
			return false;
		if (!skips("methods") && !(array(left.methods, right.methods, astFunction)))
			return false;
		if (!skips("values") && !(optionalArray(left.values, right.values, astEnumAbstractValue)))
			return false;
		if (!(span(left.span, right.span)))
			return false;
		return true;
	}

	function astCatch(left:AstCatch, right:AstCatch):Bool {
		if (!(left.name == right.name))
			return false;
		if (!(astType(left.type, right.type)))
			return false;
		if (!skips("statements") && !(array(left.statements, right.statements, astStatement)))
			return false;
		if (!(span(left.span, right.span)))
			return false;
		return true;
	}

	function astObjectField(left:AstObjectField, right:AstObjectField):Bool {
		if (!(left.name == right.name))
			return false;
		if (!(astExpression(left.value, right.value)))
			return false;
		if (!(span(left.span, right.span)))
			return false;
		return true;
	}

	function astMapEntry(left:AstMapEntry, right:AstMapEntry):Bool {
		if (!(astExpression(left.key, right.key)))
			return false;
		if (!(astExpression(left.value, right.value)))
			return false;
		if (!(span(left.span, right.span)))
			return false;
		return true;
	}

	function astSwitchExpressionCase(left:AstSwitchExpressionCase, right:AstSwitchExpressionCase):Bool {
		if (!(array(left.patterns, right.patterns, astExpression)))
			return false;
		if (!(optional(left.guard, right.guard, astExpression)))
			return false;
		if (!(astExpression(left.result, right.result)))
			return false;
		if (!(span(left.span, right.span)))
			return false;
		return true;
	}

	function astSwitchCase(left:AstSwitchCase, right:AstSwitchCase):Bool {
		if (!(array(left.patterns, right.patterns, astExpression)))
			return false;
		if (!(optional(left.guard, right.guard, astExpression)))
			return false;
		if (!skips("statements") && !(array(left.statements, right.statements, astStatement)))
			return false;
		if (!(span(left.span, right.span)))
			return false;
		return true;
	}

	function astFunction(left:AstFunction, right:AstFunction):Bool {
		if (!(left.isDynamic == right.isDynamic))
			return false;
		if (!(left.isOverride == right.isOverride))
			return false;
		if (!(left.name == right.name))
			return false;
		if (!(left.isStatic == right.isStatic))
			return false;
		if (!(left.isPublic == right.isPublic))
			return false;
		if (!(left.isExtern == right.isExtern))
			return false;
		if (!(left.isInline == right.isInline))
			return false;
		if (!(optionalArray(left.metadata, right.metadata, astMetadata)))
			return false;
		if (!(optionalValues(left.typeParameters, right.typeParameters)))
			return false;
		if (!(optionalArray(left.typeConstraints, right.typeConstraints, astTypeConstraint)))
			return false;
		if (!(array(left.arguments, right.arguments, astArgument)))
			return false;
		if (!(astType(left.result, right.result)))
			return false;
		if (!skips("statements") && !(array(left.statements, right.statements, astStatement)))
			return false;
		if (!(span(left.span, right.span)))
			return false;
		return true;
	}

	function astTypeConstraint(left:AstTypeConstraint, right:AstTypeConstraint):Bool {
		if (!(left.parameter == right.parameter))
			return false;
		if (!(astType(left.type, right.type)))
			return false;
		if (!(span(left.span, right.span)))
			return false;
		return true;
	}
}
