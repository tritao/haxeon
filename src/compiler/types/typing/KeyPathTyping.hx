package compiler.types.typing;

import compiler.Diagnostic;
import compiler.Diagnostic.CompileError;
import compiler.Source.SourceSpan;
import compiler.semantic.SemanticSignature;
import compiler.syntax.Ast.AstClass;
import compiler.syntax.Ast.AstField;
import compiler.syntax.Ast.AstType;
import compiler.types.Type.CompilerType;
import compiler.types.Type.NominalKind;
import compiler.types.TypedAst.TypedExpression;

typedef KeyPathField = {
	final owner:CompilerType;
	final declaration:AstClass;
	final field:AstField;
	final type:CompilerType;
}

typedef KeyPathDefinition = {
	final name:String;
	final root:CompilerType;
	final value:CompilerType;
	final fields:Array<KeyPathField>;
	final writable:Bool;
	final rootWriteback:Bool;
	final writeError:Null<String>;
	final span:SourceSpan;
	final origin:String;
}

/** Resolves declaration identities and capabilities before any path can become a value. */
class KeyPathTyping {
	public static inline final HELPER_PREFIX = "$keypath.";
	public static inline final LITERAL_PREFIX = "$keypath.literal:";

	public static function known(session:TypingSession, value:TypedExpression):Null<KeyPathDefinition>
		return switch value.expression {
			case TCall(name, _) if (StringTools.startsWith(name, LITERAL_PREFIX)): session.keyPathDefinitions.get(name);
			case TCast(inner), TAbiCast(inner):
				var definition = known(session, inner);
				switch value.type {
					case TKeyPath(root, fieldType, _) if (definition != null
						&& compiler.types.TypeRelations.equals(root, definition.root)
						&& compiler.types.TypeRelations.equals(fieldType, definition.value)): definition;
					default: null;
				}
			default: null;
		};

	public static function literal(session:TypingSession, parsedRoot:AstType, suffix:Array<String>, span:SourceSpan):TypedExpression {
		var path = resolveLiteral(session, parsedRoot, suffix, span, false);
		return define(session, path.root, path.value, path.fields, true, span);
	}

	/** Resolve a field identity for Diff.bit without creating a property-bypassing key path value. */
	public static function diffField(session:TypingSession, parsedRoot:AstType, suffix:Array<String>, span:SourceSpan):{
		final root:CompilerType; final value:CompilerType; final fields:Array<KeyPathField>;
	} return resolveLiteral(session, parsedRoot, suffix, span, true);

	static function resolveLiteral(session:TypingSession, parsedRoot:AstType, suffix:Array<String>, span:SourceSpan,
			allowStoredProperty:Bool):{final root:CompilerType; final value:CompilerType; final fields:Array<KeyPathField>;} {
		var rootSyntax = parsedRoot, names = suffix.copy();
		switch parsedRoot {
			case NamedType(name):
				var candidate = name, found = false;
				while (candidate.length > 0) {
					if (session.classDecls.exists(candidate) || session.declarations.aliases.exists(candidate)
						|| session.currentContext.typeSubstitutions.exists(candidate)) {
						rootSyntax = NamedType(candidate);
						var tail = name.substr(candidate.length);
						names = (tail.length == 0 ? [] : tail.substr(1).split(".")).concat(names);
						found = true;
						break;
					}
					candidate = compiler.QualifiedName.parentOrEmpty(candidate);
				}
				if (!found) fail('Cannot resolve key path root in "$name"', span);
			default:
		}
		var root = session.declarations.resolve(rootSyntax, span, session.currentContext.typeSubstitutions);
		requireRoot(session, root, span);
		if (names.length == 0) fail("A key path requires at least one stored field", span);
		var fields:Array<KeyPathField> = [], value = root;
		for (name in names) {
			switch value {
				case TNullable(_): fail('Cannot traverse nullable intermediate before "$name" in a key path', span);
				default:
			}
			var entry = resolveField(session, value, name, span);
			if (entry.field.isStatic) fail('Cannot form a key path to static field "$name"', span);
			if (!accessible(session, entry.declaration.name) && entry.field.isPublic != true)
				fail('Cannot access private field "${entry.declaration.name}.$name" in a key path', span);
			if ((entry.field.readAccess == GetAccess || entry.field.writeAccess == SetAccess
				|| entry.field.readAccess == DynamicAccess || entry.field.writeAccess == DynamicAccess)
				&& !(allowStoredProperty && DiffIntrinsics.hasStoredField(entry.field)))
				fail('Cannot form a key path to computed property "$name"', span);
			if (entry.field.readAccess == NeverAccess || entry.field.readAccess == NullAccess && !accessible(session, entry.declaration.name))
				fail('Cannot read field "$name" through a key path', span);
			fields.push(entry);
			value = entry.type;
		}
		return {root: root, value: value, fields: fields};
	}

	public static function define(session:TypingSession, root:CompilerType, value:CompilerType, fields:Array<KeyPathField>,
			grantWrite:Bool, span:SourceSpan, checkWriteAccess:Bool = true):TypedExpression {
		var writable = grantWrite, writeError:Null<String> = null, rootWriteback = true, index = fields.length;
		while (index > 0) {
			var entry = fields[--index];
			if (!DiffIntrinsics.isWritable(entry.field)
				|| checkWriteAccess && entry.field.writeAccess == NullAccess && !accessible(session, entry.declaration.name)) {
				writable = false;
				writeError = 'Cannot write through key path: field "${entry.field.name}" is not writable';
			}
			if (!session.relations.isValueClass(entry.owner)) {
				rootWriteback = false;
				if (index < fields.length - 1 && ValuePlaceRules.isObservableField(session, entry.owner, entry.field.name)) {
					writable = false;
					writeError = 'Cannot mutate a struct inside Observable field "${entry.field.name}"; copy the value, mutate it, and assign it back';
				}
				break;
			}
		}
		var identity = SemanticSignature.type(root) + ":" + [for (entry in fields) entry.declaration.name + "." + entry.field.name].join("/")
			+ (writable ? ":write" : ":read"), name = LITERAL_PREFIX + identity;
		var origin = switch root {
			case TInstance(NominalKind.Class, owner, _) if (session.signatures.exists(owner + ".new")): owner + ".new";
			default: session.currentContext.functionName;
		};
		session.keyPathDefinitions.set(name, {
			name: name,
			root: root,
			value: value,
			fields: fields,
			writable: writable,
			rootWriteback: rootWriteback,
			writeError: writeError,
			span: span,
			origin: origin
		});
		session.recordKeyPathUse(session.currentContext.name, name);
		return new TypedExpression(TCall(name, []), TKeyPath(root, value, writable), span);
	}

	static function requireRoot(session:TypingSession, type:CompilerType, span:SourceSpan):Void
		switch type {
			case TInstance(NominalKind.Class, name, _) if (session.classDecls.exists(name)):
			default: fail('Key path root must be a class or struct, got "${SemanticSignature.display(type)}"', span);
		}

	/** Unknown writable composition cannot grant a deferred tracked-struct projection. */
	public static function mayProjectTrackedStruct(session:TypingSession, root:CompilerType, known:Null<KeyPathDefinition>):Bool {
		if (known != null) {
			var index = known.fields.length;
			while (index > 0) {
				var entry = known.fields[--index];
				if (!session.relations.isValueClass(entry.owner)) return ValuePlaceRules.isObservableField(session, entry.owner, entry.field.name);
			}
			return false;
		}
		var seen:Map<String, Bool> = [];
		function visit(type:CompilerType):Bool {
			return switch type {
				case TInstance(NominalKind.Class, name, _) if (session.classDecls.exists(name) && !seen.exists(name)):
					seen.set(name, true);
					for (entry in DiffIntrinsics.conformanceFields(session, type)) {
						if (session.relations.isValueClass(entry.type) && ValuePlaceRules.isObservableField(session, type, entry.field.name)) return true;
						if (visit(entry.type)) return true;
					}
					false;
				default: false;
			};
		}
		return visit(root);
	}

	static function resolveField(session:TypingSession, owner:CompilerType, name:String, span:SourceSpan):KeyPathField {
		requireRoot(session, owner, span);
		return switch owner {
			case TInstance(NominalKind.Class, className, _):
				var declaration = session.classDecls.get(className);
				if (declaration == null) throw 'Missing key path owner "$className"';
				var substitutions = session.representation.nominalSubstitutions(owner);
				for (field in declaration.fields)
					if (field.name == name)
						return {owner: owner, declaration: declaration, field: field,
							type: session.declarations.resolve(session.declarations.resolvedFieldType(className, field), span, substitutions)};
				for (method in declaration.methods)
					if (method.name == name) fail('Cannot form a key path to method "$name"', span);
				if (declaration.base != null)
					return resolveField(session, session.declarations.resolve(declaration.base, span, substitutions), name, span);
				fail('Type "${SemanticSignature.display(owner)}" has no stored field "$name"', span);
				null;
			default: throw "Expected nominal key path owner";
		};
	}

	static function accessible(session:TypingSession, owner:String):Bool {
		var current = session.currentContext.owner;
		while (current != null) {
			if (current == owner) return true;
			var declaration = session.classDecls.get(current);
			if (declaration == null || declaration.base == null) return false;
			current = switch declaration.base {
				case NamedType(name), AppliedType(name, _): name;
				default: null;
			};
		}
		return false;
	}

	static function fail(message:String, span:SourceSpan):Void
		throw new CompileError(new Diagnostic("E1009", message, span));
}
