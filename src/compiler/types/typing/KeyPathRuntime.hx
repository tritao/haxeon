package compiler.types.typing;

import compiler.types.TypedAst.TypedFunctionRole;
import compiler.Source.SourceSpan;
import compiler.semantic.SemanticSignature;
import compiler.types.KeyPathType;
import compiler.types.Type.CompilerType;
import compiler.types.TypedAst.TypedClass;
import compiler.types.TypedAst.TypedField;
import compiler.types.TypedAst.TypedFunction;
import compiler.types.TypedAst.TypedExpression;
import compiler.types.TypedAst.TypedStatement;
import compiler.types.typing.KeyPathTyping.KeyPathDefinition;
import haxe.crypto.Sha256;

/** Shared descriptors own typed access functions; calling them never builds a writer. */
class KeyPathRuntime {
	final session:TypingSession;
	final emitted:Map<String, Bool> = [];
	final caches:Map<String, TypedClass> = [];
	public final newClasses:Array<TypedClass> = [];

	public function new(session:TypingSession, classes:Array<TypedClass>) {
		this.session = session;
		for (declaration in classes)
			if (declaration.name.indexOf(".$keypaths$") >= 0) caches.set(declaration.name, declaration);
	}

	public function drain():Array<TypedFunction> {
		var pending = [for (name in session.keyPathDefinitions.keys()) if (!emitted.exists(name)) name], result:Array<TypedFunction> = [];
		pending.sort(Reflect.compare);
		for (name in pending) {
			emitted.set(name, true);
			var definition = session.keyPathDefinitions.get(name);
			if (definition == null) throw 'Missing key path definition "$name"';
			var span = definition.span,
				pathType = TKeyPath(definition.root, definition.value, definition.writable),
				cacheName = cacheOwner(definition), fieldName = "$p$" + Sha256.encode(name).substr(0, 32),
				cache = caches.get(cacheName);
			new AnonymousTypeRegistry(session).register(pathType);
			if (cache == null) {
				cache = {name: cacheName, isValue: false, isFlat: false, isPortable: false, isNativeValue: false,
					nativeLayouts: [], base: null, interfaces: [], fields: [], methods: [], span: span};
				caches.set(cacheName, cache);
				newClasses.push(cache);
			}
			var hasField = false;
			for (field in cache.fields) if (field.name == fieldName) hasField = true;
			if (!hasField) cache.fields.push({name: fieldName, type: pathType, metadata: [],
				initializer: nil(pathType, span), inlineValue: null,
				readAccess: null, writeAccess: null, isStatic: true, isInline: false, isFinal: false, span: span});
			var readName = name + ":read", writeName = name + ":write",
				steps = [for (entry in definition.fields) "/" + entry.declaration.name + "." + entry.field.name].join(""),
				tail = [for (entry in definition.fields) entry.field.name].join("."),
				getterType = TFunction([definition.root], definition.value), setterType = TFunction([definition.root, definition.value], definition.root),
				values:Array<compiler.types.TypedAst.TypedObjectField> = [
					{name: "$get", value: new TypedExpression(TFunctionRef(readName), getterType, span)},
					{name: "$set", value: definition.writable ? new TypedExpression(TFunctionRef(writeName), setterType, span) : nil(setterType, span)},
					{name: "$key", value: string(SemanticSignature.type(definition.root) + ":" + steps, span)},
					{name: "$steps", value: string(steps, span)}, {name: "$tail", value: string(tail, span)},
					{name: "$display", value: string("\\" + SemanticSignature.display(definition.root) + "." + tail, span)},
					{name: "$writeback", value: new TypedExpression(TBoolLiteral(definition.rootWriteback), TBool, span)}
				],
				created = new TypedExpression(TObjectLiteral(KeyPathType.descriptorName(definition.root, definition.value),
					[for (entry in values) {name: entry.name, value: entry.value}], false), pathType, span),
				cached = new TypedExpression(TStaticField(cacheName, fieldName), pathType, span),
				missing = new TypedExpression(TEqual(cached, nil(pathType, span)), TBool, span);
			result.push(fn(name, definition, [], pathType, [TIf(missing, [TStaticFieldAssign(cacheName, fieldName, created, span)], [], span), TReturn(cached, span)]));
			var root = new TypedExpression(TLocal("root"), definition.root, span), value = root;
			for (entry in definition.fields) value = field(value, entry.field.name, span);
			result.push(fn(readName, definition, [{name: "root", type: definition.root}], definition.value, [TReturn(value, span)]));
			if (definition.writable) {
				var target = root;
				for (index in 0...definition.fields.length - 1) target = field(target, definition.fields[index].field.name, span);
				var last = definition.fields[definition.fields.length - 1],
					physical = session.representation.resolveField(target.type, last.field.name, span).physical,
					assigned = session.representation.boundaryCast(new TypedExpression(TLocal("value"), definition.value, span), physical);
				result.push(fn(writeName, definition, [{name: "root", type: definition.root}, {name: "value", type: definition.value}], definition.root,
					[TFieldAssign(target, last.field.name, assigned, span), TReturn(root, span)]));
			}
		}
		return result;
	}

	function field(receiver:TypedExpression, name:String, span:SourceSpan):TypedExpression {
		var representation = session.representation.resolveField(receiver.type, name, span);
		return session.representation.boundaryCast(new TypedExpression(TField(receiver, name), representation.physical, span), representation.semantic);
	}

	static function cacheOwner(definition:KeyPathDefinition):String {
		var rootName = switch definition.root { case TInstance(_, name, _): name; default: throw "Invalid key path root"; };
		return rootName + ".$keypaths$" + Sha256.encode(SemanticSignature.type(definition.root)).substr(0, 16);
	}

	static function string(value:String, span:SourceSpan):TypedExpression
		return new TypedExpression(TStringLiteral(value), TString, span);

	static function nil(type:CompilerType, span:SourceSpan):TypedExpression
		return new TypedExpression(TNullableWrap(new TypedExpression(TNullLiteral, TNull, span)), type, span);

	static function fn(name:String, definition:KeyPathDefinition, arguments:Array<{name:String, type:CompilerType}>, result:CompilerType,
			statements:Array<TypedStatement>):TypedFunction
		return {name: name, role: KeyPathFunction, origin: definition.origin, originKind: Helper, owner: null, isStatic: true, isConstructor: false,
			arguments: arguments, result: result, statements: statements, cells: [], cellCaptures: [], span: definition.span};
}
