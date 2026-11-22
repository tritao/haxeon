package compiler.types.typing;

import compiler.NullSafetyRule;
import compiler.NullSafetyRule.NullSafetyMode;
import compiler.core.Diagnostic;
import compiler.core.Source.SourceSpan;
import compiler.semantic.SemanticSignature;
import compiler.syntax.Ast.AstMetadata;
import compiler.types.Monomorphs;
import compiler.types.Type.CompilerType;
import compiler.types.Type.NominalKind;
import compiler.types.TypedAst.TypedExpression;

/**
 * Where a value meets a type that does not take null, as the null-safety checker names it: what its message says and where it
 * points, as Haxe's checker reports each (`nullSafety.ml`). A conversion no source construct asks for is `Unchecked`.
 */
enum NullSafetyUse {
	Unchecked;

	/** A local's declaration or an assignment, at the whole statement (`var x:String = s`). */
	Assignment(span:SourceSpan);

	/** A field's initializer, at the field's declaration. */
	FieldInitializer(field:String, span:SourceSpan);

	/** Argument `position` (from 1) of a call to `callee`, a function's qualified name or a method's display name. */
	Argument(callee:String, position:Int);

	/** A builtin method's argument, named as Haxe's standard library names it (`push`'s `x`). */
	NamedArgument(callee:String, name:String);

	Return(span:SourceSpan);

	/** An item of an array literal or comprehension. */
	ArrayItem;

	/** A typed cast or a type check, at the whole expression. */
	Cast(span:SourceSpan);

	/** An operand of the binary operator at `span`. */
	Operand(span:SourceSpan);

	/** The operand of the unary operator at `span`. */
	UnaryOperand(span:SourceSpan);

	/** The index of the array access at `span`. */
	Index(span:SourceSpan);

	/** The condition of an `if` (also a ternary's or a guard's) or a `while`, by its keyword. */
	Condition(keyword:String);
}

/**
 * Haxe's null-safety checker (`@:nullSafety(Mode)`, docs/reference/LANGUAGE_SUPPORT.md, "Null safety"): where a body's mode is
 * on, a `Null<T>` the flow facts do not prove present may not reach a place that does not take null, nor be read through. It
 * checks as the typer meets each place, with the narrowing the typer already does (`FlowAnalysis`), and changes no code. A body's
 * findings are errors (`E1005`), or warnings (`W1003`) for a package whose setting is `warn`; the errors are kept until the
 * typing ends, so one body reports all of its own.
 */
class NullSafety {
	public static inline final ERROR = "E1005";
	public static inline final WARNING = "W1003";

	final session:TypingSession;

	/** The compile's rules (`CompileOptions.nullSafety`). */
	public var rules:Array<NullSafetyRule> = [];

	/** The errors found so far; a checkpoint keeps their count, and what typing then abandons drops its own. */
	public final findings:Array<Diagnostic> = [];

	public function new(session:TypingSession)
		this.session = session;

	// --- Modes

	/** Sets `context`'s mode: a lambda's is its function's; a declared body's comes from its declaration, which a generated body has none of. */
	public function enter(context:TypingContext, outer:Null<TypingContext>):Void {
		if (outer != null && compiler.semantic.LambdaName.is(context.name)) {
			context.nullSafetyMode = outer.nullSafetyMode;
			context.nullSafetyWarns = outer.nullSafetyWarns;
			context.nullSafetyOffDepth = outer.nullSafetyOffDepth;
			context.nullSafetyClosure = outer.nullSafetyClosure;
			return;
		}
		var owner = context.owner, source = context.sourceFunctionName;
		if (owner == null) {
			enterModuleFunction(context, source);
			return;
		}
		if (!StringTools.startsWith(source, owner + "."))
			return;
		var member = source.substr(owner.length + 1);
		var field = compiler.semantic.InitializerUnit.field(source);
		if (field != null)
			member = field.substr(field.lastIndexOf(".") + 1);
		if (member.indexOf(".") >= 0 || member.indexOf("$") >= 0)
			return;
		var declaration = declarationOf(owner);
		if (declaration == null)
			return;
		var memberMetadata = declaration.member(member);
		if (memberMetadata == null)
			return;
		var resolved = resolve(owner, declaration, memberMetadata);
		context.nullSafetyMode = resolved.mode;
		context.nullSafetyWarns = resolved.warns;
	}

	/**
	 * A module-level function `name`: a static of its module's class, as Haxe makes it, so the rules on the module reach it, and its
	 * own metadata.
	 */
	function enterModuleFunction(context:TypingContext, name:String):Void {
		var fn = session.signatures.get(name);
		if (fn == null || fn.isExtern == true || name.indexOf("$") >= 0)
			return;
		var path = fn.span.file.path,
			slash = Std.int(Math.max(path.lastIndexOf("/"), path.lastIndexOf("\\"))),
			file = path.substr(slash + 1),
			dot = name.lastIndexOf(".");
		if (StringTools.endsWith(file, ".hx"))
			file = file.substr(0, file.length - 3);
		var moduleClass = dot < 0 ? file : name.substr(0, dot) + "." + file,
			resolved = resolve(moduleClass, {metadata: [], span: fn.span, member: _ -> null},
				fn.metadata == null ? [] : fn.metadata);
		context.nullSafetyMode = resolved.mode;
		context.nullSafetyWarns = resolved.warns;
	}

	/** The metadata of `owner`'s declaration and of its members, or null for a declaration the checker does not check. */
	function declarationOf(owner:String):Null<CheckedDeclaration> {
		var classDecl = session.classDecls.get(owner);
		if (classDecl != null)
			return classDecl.isExtern == true ? null : {metadata: classDecl.metadata,
				span: classDecl.span,
				member: name -> {
					for (method in classDecl.methods)
						if (method.name == name)
							return method.metadata == null ? [] : method.metadata;
					for (field in classDecl.fields)
						if (field.name == name)
							return field.metadata;
					return null;
				}
			};
		var abstractDecl = session.declarations.abstractDeclaration(owner);
		if (abstractDecl != null)
			return abstractDecl.isExtern == true
				? null : {metadata: abstractDecl.metadata == null ? [] : abstractDecl.metadata,
				span: abstractDecl.span,
				member: name -> {
					for (method in abstractDecl.methods)
						if (method.name == name)
							return method.metadata == null ? [] : method.metadata;
					for (field in abstractDecl.fields)
						if (field.name == name)
							return field.metadata;
					return null;
				}
			};
		return null;
	}

	/** The mode of the class or abstract `owner` alone (its rules and metadata), which decides whether its fields' initialization is checked. */
	public function declarationMode(owner:String):{mode:NullSafetyMode, warns:Bool} {
		var declaration = declarationOf(owner);
		return declaration == null ? {mode: Off, warns: false} : resolve(owner, declaration, []);
	}

	/** The mode of a member with `memberMetadata` of `owner`, as Haxe's `safety_mode` reads the rules, the type's metadata, then the member's. */
	public function memberMode(owner:String, memberMetadata:Array<AstMetadata>):{mode:NullSafetyMode, warns:Bool} {
		var declaration = declarationOf(owner);
		return declaration == null ? {mode: Off, warns: false} : resolve(owner, declaration, memberMetadata);
	}

	function resolve(owner:String, declaration:CheckedDeclaration,
			memberMetadata:Array<AstMetadata>):{
				mode:NullSafetyMode,
				warns:Bool
			} {
		// The standard library is not checked, as stock Haxe's is not unless a rule names it.
		if (declaration.span.file.isStandardLibrarySource)
			return {mode: Off, warns: false};
		var entries:Array<NullSafetyMode> = [];
		if (rules.length > 0) {
			var typeName = owner.substr(owner.lastIndexOf(".") + 1),
				modulePath = modulePathOf(owner, declaration.span);
			for (rule in rules)
				if (rule.matches(modulePath, typeName))
					entries.push(rule.mode);
		}
		for (entry in declaration.metadata)
			if (entry.name == "nullSafety")
				entries.push(metadataMode(entry));
		for (entry in memberMetadata)
			if (entry.name == "nullSafety")
				entries.push(metadataMode(entry));
		if (entries.length == 0)
			return {mode: Off, warns: false};
		// Haxe's `safety_mode`: Off anywhere wins, Strict and StrictThreaded override, and Loose applies only when nothing came before.
		var mode:Null<NullSafetyMode> = null, warnsOnly = true;
		for (entry in entries) {
			switch entry {
				case Off:
					return {mode: Off, warns: false};
				case Loose:
					if (mode == null)
						mode = Loose;
					warnsOnly = false;
				case Warn:
					mode = Strict;
				case Strict, StrictThreaded:
					mode = entry;
					warnsOnly = false;
			}
		}
		return mode == null ? {mode: Off, warns: false} : {mode: mode, warns: warnsOnly};
	}

	/** A module's dot path from the type's package and its file's name, which holds wherever the file was loaded from. */
	static function modulePathOf(owner:String, span:SourceSpan):String {
		var path = span.file.path,
			slash = Std.int(Math.max(path.lastIndexOf("/"), path.lastIndexOf("\\"))),
			file = path.substr(slash + 1);
		if (StringTools.endsWith(file, ".hx"))
			file = file.substr(0, file.length - 3);
		var dot = owner.lastIndexOf(".");
		return dot < 0 ? file : owner.substr(0, dot) + "." + file;
	}

	/** The mode `@:nullSafety(...)` states; with no argument it is Loose, as in Haxe. An argument Haxe does not take is an error. */
	function metadataMode(entry:AstMetadata):NullSafetyMode {
		if (entry.arguments.length == 0)
			return Loose;
		var mode = entry.arguments.length == 1 ? switch entry.arguments[0] {
			case Variable("Off", _): Off;
			case Variable("Loose", _): Loose;
			case Variable("Strict", _): Strict;
			case Variable("StrictThreaded", _): StrictThreaded;
			default: null;
		} : null;
		if (mode == null) {
			findings.push(new Diagnostic(ERROR, "Null safety: Invalid argument for @:nullSafety meta", entry.span));
			return Off;
		}
		return mode;
	}

	/** Whether `metadata` turns the checker off (`@:nullSafety(Off)`). */
	public static function turnsOff(metadata:Array<AstMetadata>):Bool {
		for (entry in metadata)
			if (entry.name == "nullSafety" && entry.arguments.length == 1)
				switch entry.arguments[0] {
					case Variable("Off", _):
						return true;
					default:
				}
		return false;
	}

	/** Whether the body being typed is checked. */
	public inline function active():Bool
		return session.hasBody() && session.currentContext.nullSafetyMode != Off
			&& session.currentContext.nullSafetyOffDepth == 0;

	// --- Reporting

	/** Reports `message` at `span` in the body being typed, as its mode reports. */
	public function report(message:String, span:SourceSpan):Void {
		var context = session.currentContext;
		if (context.nullSafetyWarns)
			session.warn(new Diagnostic(WARNING, "Null safety: " + message, span, Warning));
		else
			findings.push(new Diagnostic(ERROR, "Null safety: " + message, span));
	}

	/** Reports a finding outside any body: one of a class's fields, as an error or into `warnings`. */
	public function reportFor(warns:Bool, message:String, span:SourceSpan, warnings:Null<Array<Diagnostic>>):Void {
		if (!warns)
			findings.push(new Diagnostic(ERROR, "Null safety: " + message, span));
		else if (warnings != null)
			warnings.push(new Diagnostic(WARNING, "Null safety: " + message, span, Warning));
	}

	/** The findings from `from` on, once each, for the typing's failure. */
	public function takeFindings():Array<Diagnostic> {
		var result:Array<Diagnostic> = [];
		for (finding in findings) {
			var seen = false;
			for (existing in result)
				if (existing.message == finding.message && existing.span.start == finding.span.start
					&& existing.span.end == finding.span.end && existing.span.file.path == finding.span.file.path) {
					seen = true;
					break;
				}
			if (!seen)
				result.push(finding);
		}
		findings.resize(0);
		return result;
	}

	// --- What is nullable

	/** Whether `type` takes null, as Haxe's `is_nullable_type` with Dynamic counted: `Null<T>`, Dynamic, or a type still open. */
	public static function acceptsNull(type:CompilerType):Bool
		return switch Monomorphs.follow(type) {
			case TNullable(_), TNull, TDynamic, TMonomorph(_), TVoid: true;
			case TAbstract(_, _, representation): switch representation {
					case TNullable(_): true;
					default: false;
				};
			default: false;
		};

	/**
	 * Whether `value` may be null where the checker reads it: its type is nullable after the flow facts, or the mode does not trust
	 * the fact that made it present. A Loose body trusts a field's narrowing across calls, which the typer's facts forget.
	 */
	public function isNullable(value:TypedExpression):Bool {
		var context = session.currentContext;
		return switch value.type {
			case TNull: true;
			case TNullable(_):
				!(context.nullSafetyMode == Loose && provedAcrossCalls(value));
			default:
				switch value.expression {
					case TNullLiteral: true;
					// A closure Strict checks may run after its captured local changed, so it trusts no narrowing of one.
					case TCaptured(_) if (context.nullSafetyClosure && context.nullSafetyMode != Loose):
						var stored = value.storageType;
						stored != null && stored.match(TNullable(_));
					// StrictThreaded narrows no field but a final one: another thread may write it.
					case TCast(field) if (context.nullSafetyMode == StrictThreaded):
						field.type.match(TNullable(_)) && isMutableField(field);
					default: false;
				}
		};
	}

	/** Whether `value`, a field path's read, was narrowed before a call the typer let forget it (`FlowFacts.resolveAcrossCalls`). */
	function provedAcrossCalls(value:TypedExpression):Bool {
		var scope = session.currentContext.flowScope;
		if (scope == null)
			return false;
		return switch value.expression {
			case TField(_, _), TStaticField(_, _):
				var proved = scope.resolveAccessAcrossCalls(value);
				proved != null && !acceptsNull(proved);
			default: false;
		};
	}

	function isMutableField(field:TypedExpression):Bool
		return switch field.expression {
			case TField(object, name): !isFinalField(object.type, name);
			case TStaticField(owner, name): !isFinalStatic(owner, name);
			default: false;
		};

	function isFinalField(type:CompilerType, name:String):Bool
		return switch type {
			case TInstance(NominalKind.Class, className, _):
				var declaration = session.classDecls.get(className);
				if (declaration == null) false else {
					var found = false, isFinal = false;
					for (field in declaration.fields)
						if (field.name == name && !field.isStatic) {
							found = true;
							isFinal = field.isFinal;
						}
					found ? isFinal : declaration.base != null
						&& isFinalField(session.declarations.resolve(declaration.base, declaration.span), name);
				}
			case TAnonymous(_, fields):
				var isFinal = false;
				for (field in fields)
					if (field.name == name)
						isFinal = field.isFinal;
				isFinal;
			default: false;
		};

	function isFinalStatic(owner:String, name:String):Bool {
		var declaration = session.classDecls.get(owner);
		if (declaration != null)
			for (field in declaration.fields)
				if (field.name == name && field.isStatic)
					return field.isFinal;
		return false;
	}

	// --- Checks

	/** Where `value` meets `expected`: a nullable value where null is not taken, then a nullable element where it is not (`Array<Null<T>>` as `Array<T>`). */
	public function checkConversion(value:TypedExpression, expected:CompilerType, use:NullSafetyUse):Void {
		if (use == Unchecked || !active())
			return;
		var expectedType = Monomorphs.follow(expected);
		if (acceptsNull(expectedType))
			return;
		if (isNullable(value)) {
			reportUse(use, value, expectedType);
			return;
		}
		var actual = unfoldNull(Monomorphs.follow(value.type));
		if (nestedMismatch(actual, expectedType, 0))
			report('Cannot unify ${SemanticSignature.display(actual)} with ${SemanticSignature.display(expectedType)}',
				switch use {
					case Assignment(span), Return(span), Cast(span), FieldInitializer(_, span): span;
					default: value.span;
				});
	}

	function reportUse(use:NullSafetyUse, value:TypedExpression, expected:CompilerType):Void
		switch use {
			case Unchecked:
			case Assignment(span):
				report("Cannot assign nullable value here.", span);
			case FieldInitializer(field, span):
				report('Cannot set nullable initial value for not-nullable field "$field".', span);
			case Argument(callee, position):
				var parameter = parameterName(callee, position);
				if (parameter == null)
					return;
				report('Cannot pass nullable value to not-nullable argument${parameter == "" ? "" : ' "$parameter"'}'
					+ ' of function "${displayName(callee)}".', value.span);
			case NamedArgument(callee, name):
				report('Cannot pass nullable value to not-nullable argument "$name" of function "$callee".',
					value.span);
			case Return(span):
				report('Cannot return nullable value of ${SemanticSignature.display(value.type)} as ${SemanticSignature.display(expected)}',
					span);
			case ArrayItem:
				// A null literal has the element's type in Haxe's message.
				var item = value.type.match(TNull) ? expected : value.type;
				report('Cannot use nullable value of ${SemanticSignature.display(item)} as an item in Array<${SemanticSignature.display(expected)}>',
					value.span);
			case Cast(span):
				report("Cannot cast nullable value to not nullable type.", span);
			case Operand(span):
				report("Cannot perform binary operation on nullable value.", span);
			case UnaryOperand(span):
				report("Cannot perform unary operation on nullable value.", span);
			case Index(span):
				report("Cannot use nullable value as an index for array access.", span);
			case Condition(keyword):
				report('Cannot use nullable value as ${keyword == "while" ? "a " : ""}condition in "$keyword".',
					value.span);
		}

	/**
	 * The name of argument `position` of `callee`, "" when it has none to give (a function value's), or null when the argument is
	 * optional: a call may leave it out, so Haxe lets it take null.
	 */
	function parameterName(callee:String, position:Int):Null<String> {
		var signature = session.signatures.get(callee);
		if (signature == null)
			return "";
		var argument = signature.arguments[position - 1];
		if (argument == null)
			return "";
		return compiler.syntax.AstPredicates.isOptionalArgument(argument) ? null : argument.name;
	}

	/** The name a message gives a callee: a method's or function's own name, `new` for a constructor. */
	static function displayName(callee:String):String
		return callee.substr(callee.lastIndexOf(".") + 1);

	static function unfoldNull(type:CompilerType):CompilerType
		return switch type {
			case TNullable(element): unfoldNull(element);
			default: type;
		};

	/** Haxe's `unificator`: whether a `Null<T>` inside `actual` meets a place inside `expected` that does not take null. */
	static function nestedMismatch(actual:CompilerType, expected:CompilerType, depth:Int):Bool {
		// A structure can contain itself; nullability deeper than this is not worth the walk.
		if (depth > 6)
			return false;
		actual = Monomorphs.follow(actual);
		expected = Monomorphs.follow(expected);
		switch expected {
			case TNullable(_), TDynamic, TMonomorph(_):
				return false;
			default:
		}
		switch actual {
			case TNullable(_):
				return depth > 0;
			default:
		}
		return switch [actual, expected] {
			case [TArray(a), TArray(b)], [TIterator(a), TIterator(b)]: nestedMismatch(a, b, depth + 1);
			case [TMap(ak, av), TMap(bk, bv)]: nestedMismatch(ak, bk, depth + 1) || nestedMismatch(av, bv, depth + 1);
			case [TInstance(_, _, as), TInstance(_, _, bs)] if (as.length == bs.length): anyMismatch(as, bs, depth);
			case [TAbstract(a, as, _), TAbstract(b, bs, _)] if (a == b && as.length == bs.length): anyMismatch(as, bs,
				depth);
			case [TFunction(aArguments, aResult, _), TFunction(bArguments, bResult, _)]:
				if (!bResult.match(TVoid) && nestedMismatch(aResult, bResult, depth + 1))
					true;
				else {
					var mismatch = false;
					for (index in 0...Std.int(Math.min(aArguments.length, bArguments.length)))
						// An argument goes the other way: the function given must take whatever the expected one is passed.
						if (nestedMismatch(bArguments[index], aArguments[index], depth + 1))
							mismatch = true;
					mismatch;
				}
			case [TAnonymous(_, aFields), TAnonymous(_, bFields)]:
				var mismatch = false;
				for (field in bFields)
					for (own in aFields)
						if (own.name == field.name && nestedMismatch(own.type, field.type, depth + 1))
							mismatch = true;
				mismatch;
			default: false;
		};
	}

	static function anyMismatch(actual:Array<CompilerType>, expected:Array<CompilerType>, depth:Int):Bool {
		for (index in 0...actual.length)
			if (nestedMismatch(actual[index], expected[index], depth + 1))
				return true;
		return false;
	}

	/** A member of `receiver` read, written or called at `span`. */
	public function checkReceiver(receiver:TypedExpression, member:String, span:SourceSpan):Void
		if (active() && isNullable(receiver))
			report('Cannot access "$member" of a nullable value.', span);

	/** A call of the function value `callee`. */
	public function checkCallee(callee:TypedExpression):Void
		if (active() && isNullable(callee))
			report("Cannot call a nullable value.", callee.span);

	/** An array access on `array`, at `span`. */
	public function checkArrayAccess(array:TypedExpression, span:SourceSpan):Void
		if (active() && isNullable(array))
			report("Cannot perform array access on nullable value.", span);

	/** A `for` over `iterable`. */
	public function checkIterable(iterable:TypedExpression):Void
		if (active() && isNullable(iterable))
			report("Cannot iterate over nullable value.", iterable.span);

	/** A `throw` of `value`, at `span`. */
	public function checkThrow(value:TypedExpression, span:SourceSpan):Void
		if (active() && isNullable(value))
			report("Cannot throw nullable value.", span);

	/** `left + right` at `span` where one is a String: a concatenation takes one nullable operand, as Haxe's does, but not two. */
	public function checkConcatenation(left:TypedExpression, right:TypedExpression, span:SourceSpan):Void
		if (active() && left.type.match(TNullable(_) | TNull) && right.type.match(TNullable(_) | TNull))
			report("Cannot concatenate two nullable values.", span);

	/** The span of `object.name` in `object.name(...)` at `span`, `object` at `objectSpan`: from the receiver to the name's end, as Haxe points. */
	public static function memberSpan(objectSpan:SourceSpan, name:String, span:SourceSpan):SourceSpan {
		var file = span.file, at = objectSpan.end;
		if (objectSpan.file != file || at < span.start || at > span.end)
			return span;
		while (at < span.end && isSeparator(file.bytes.get(at)))
			at++;
		var length = file.utf8LengthAt(at, name);
		return length < 0 || at + length > span.end ? span : new SourceSpan(file, objectSpan.start, at + length);
	}

	static function isSeparator(code:Int):Bool
		return code == ".".code || code == "?".code || code == " ".code || code == "\t".code || code == "\n".code
			|| code == "\r".code;
}

/** The metadata of a checked declaration and a lookup of its members', null for a member it does not declare. */
private typedef CheckedDeclaration = {
	final metadata:Array<AstMetadata>;
	final span:SourceSpan;
	final member:String->Null<Array<AstMetadata>>;
}
