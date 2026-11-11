package compiler.types.typing;

import compiler.types.TypedAst.TypedFunctionRole;
import compiler.Source.SourceSpan;
import compiler.types.Type.CompilerType;
import compiler.types.TypedAst;
import compiler.types.KeyPathType;
import compiler.semantic.SemanticSignature;

/** Concatenation owns its closures; dispatch itself only passes typed values. */
class KeyPathComposition {
	public static function create(session:TypingSession, left:TypedExpression, right:TypedExpression,
			root:CompilerType, middle:CompilerType, value:CompilerType, writable:Bool, span:SourceSpan):TypedExpression {
		var name = "$keypath.compose:" + session.currentContext.functionName + ":" + span.start + ":"
			+ haxe.crypto.Sha256.encode(SemanticSignature.type(left.type) + SemanticSignature.type(right.type)).substr(0, 16),
			environment = name + ":environment", type = TKeyPath(root, value, writable),
			statements:Array<TypedStatement> = [], p = KeyPathOperations.hold(session, left, "left", span, statements),
			q = KeyPathOperations.hold(session, right, "right", span, statements),
			captures:Array<TypedCapture> = [
				{field: "left", bindingId: "left", type: left.type, storageType: left.type, source: CaptureExpression(p)},
				{field: "right", bindingId: "right", type: right.type, storageType: right.type, source: CaptureExpression(q)}
			],
			cp = new TypedExpression(TCaptured("left"), left.type, span), cq = new TypedExpression(TCaptured("right"), right.type, span),
			r = local("root", root, span), v = local("value", value, span),
			mid = get(cp, r, middle, span), read = get(cq, mid, value, span),
			getterType = TFunction([root], value), setterType = TFunction([root, value], root);
		for (pathType in [left.type, right.type, type]) new AnonymousTypeRegistry(session).register(pathType);
		session.closureConversion.addEnvironment(environment, captures);
		function add(suffix:String, arguments:Array<{name:String, type:CompilerType}>, result:CompilerType, body:Array<TypedStatement>):Void {
			if (session.keyPathCompositions.exists(name + suffix)) return;
			session.keyPathCompositions.set(name + suffix, true);
			session.closureConversion.addFunction({name: name + suffix, role: ProviderFunction(root, compiler.Provides.ProviderOperations.detailed(compiler.Provides.ProviderOperation.KeyPath, name + suffix)), origin: session.currentContext.functionName, originKind: Helper,
				owner: environment, isStatic: false, isConstructor: false, arguments: arguments, result: result, statements: body,
				cells: [], cellCaptures: [], span: span});
		}
		add(":get", [{name: "root", type: root}], value, [TReturn(read, span)]);
		if (writable) {
			var body:Array<TypedStatement> = [TVar("middle", mid, span)], m = local("middle", middle, span),
				updated = set(cq, m, v, middle, span), result = local("updated", middle, span);
			body.push(TVar("updated", updated, span));
			if (session.relations.isValueClass(middle))
				body.push(TIf(field(cq, "$writeback", TBool, span), [TReturn(set(cp, r, result, root, span), span)], [], span));
			body.push(TReturn(r, span));
			add(":set", [{name: "root", type: root}, {name: "value", type: value}], root, body);
		}
		var fields:Array<TypedObjectField> = [
			{name: "$get", value: new TypedExpression(TLambda(name + ":get", environment, captures), getterType, span)},
			{name: "$set", value: writable ? new TypedExpression(TLambda(name + ":set", environment, captures), setterType, span)
				: new TypedExpression(TNullableWrap(new TypedExpression(TNullLiteral, TNull, span)), setterType, span)},
			{name: "$key", value: addStrings(field(p, "$key", TString, span), field(q, "$steps", TString, span), span)},
			{name: "$steps", value: addStrings(field(p, "$steps", TString, span), field(q, "$steps", TString, span), span)},
			{name: "$tail", value: dotted(field(p, "$tail", TString, span), field(q, "$tail", TString, span), span)},
			{name: "$display", value: dotted(field(p, "$display", TString, span), field(q, "$tail", TString, span), span)},
			{name: "$writeback", value: new TypedExpression(TAnd(field(p, "$writeback", TBool, span), field(q, "$writeback", TBool, span)), TBool, span)}
		];
		return new TypedExpression(TBlockExpression(statements,
			new TypedExpression(TObjectLiteral(KeyPathType.descriptorName(root, value), fields, false), type, span)), type, span);
	}

	static function local(name:String, type:CompilerType, span:SourceSpan):TypedExpression return new TypedExpression(TLocal(name), type, span);
	static function field(path:TypedExpression, name:String, type:CompilerType, span:SourceSpan):TypedExpression return new TypedExpression(TField(path, name), type, span);
	static function get(path:TypedExpression, root:TypedExpression, value:CompilerType, span:SourceSpan):TypedExpression
		return new TypedExpression(TClosureCall(field(path, "$get", TFunction([root.type], value), span), [root]), value, span);
	static function set(path:TypedExpression, root:TypedExpression, value:TypedExpression, result:CompilerType, span:SourceSpan):TypedExpression
		return new TypedExpression(TClosureCall(field(path, "$set", TFunction([root.type, value.type], result), span), [root, value]), result, span);
	static function addStrings(a:TypedExpression, b:TypedExpression, span:SourceSpan):TypedExpression return new TypedExpression(TAdd(a, b), TString, span);
	static function dotted(a:TypedExpression, b:TypedExpression, span:SourceSpan):TypedExpression
		return addStrings(addStrings(a, new TypedExpression(TStringLiteral("."), TString, span), span), b, span);
}
