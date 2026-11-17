package compiler.types.typing;

import compiler.core.Source.SourceSpan;
import compiler.semantic.SemanticProgram.SemanticMethodInfo;
import compiler.syntax.Ast;

/** A class's field, with the class that declares it. */
typedef DeclaredField = {
	final declaration:AstClass;
	final field:AstField;
}

/** A member that source names, as written where it is declared. */
typedef DeclaredMember = {
	/** The class, interface or abstract that declares it. */
	final owner:String;

	final name:String;

	/** Its visibility as written: true for `public`, false for `private`, null with no modifier. */
	final isPublic:Null<Bool>;

	final ownerMetadata:Array<AstMetadata>;
	final metadata:Null<Array<AstMetadata>>;
}

/**
 * The typer's one way to the members of classes, interfaces and abstracts.
 *
 * The lookups (`classField`, `methodInfo`) are pure: representation queries, generated code, inference and probes use them freely.
 * The access entry points (`field`, `method`) are for a member the user's source names: a field read or write, a method call or
 * method value, a static, a constructor, `super`. Each finds the member where it is declared and requires that the code reaching it
 * may, which is where Haxe's `private` is decided (`canAccess`: the declaring class and its subclasses, `@:allow`, `@:access`,
 * `@:privateAccess`). A site the compiler generates, or one that reads a member for its own reasons, does not call them.
 */
class MemberAccess {
	/** The field `name` of class `className` or of the nearest base class declaring it; static or instance as `isStatic` asks. */
	public static function classField(session:TypingSession, className:String, name:String,
			isStatic:Bool):Null<DeclaredField> {
		var owner:Null<String> = className, seen:Map<String, Bool> = [];
		while (owner != null) {
			if (seen.exists(owner))
				throw 'Cyclic class hierarchy while resolving "$className.$name"';
			seen.set(owner, true);
			var declaration = session.classDecls.get(owner);
			if (declaration == null)
				return null;
			for (field in declaration.fields)
				if (field.name == name && field.isStatic == isStatic)
					return {declaration: declaration, field: field};
			owner = declaration.base == null ? null : baseName(declaration.base);
		}
		return null;
	}

	/** The method `name` of `className`, its base classes or (for an interface) its base interfaces, first found first. */
	public static function methodInfo(session:TypingSession, className:String, name:String):Null<SemanticMethodInfo> {
		var results:Array<SemanticMethodInfo> = [];
		findMethods(session, className, name, results);
		return results.length == 0 ? null : results[0];
	}

	static function findMethods(session:TypingSession, className:String, name:String,
			results:Array<SemanticMethodInfo>):Void {
		if (results.length > 0)
			return;
		var key = className + "." + name, info = session.methodInfo.get(key);
		if (info != null) {
			results.push(info);
			return;
		}
		var classDecl = session.classDecls.get(className);
		if (classDecl != null) {
			var base = classDecl.base;
			if (base != null)
				findMethods(session, BodyTyper.inheritanceName(base), name, results);
			return;
		}
		var interfaceDecl = session.interfaceDecls.get(className);
		if (interfaceDecl != null)
			for (base in interfaceDecl.bases)
				findMethods(session, BodyTyper.inheritanceName(base), name, results);
	}

	/**
	 * Source names the field `name` of class `className` (an instance field of a value of that class, or a static through the
	 * class): requires that it may be reached from here. A name that is not a class field (a platform field, an interface's or a
	 * structure's) has nothing to require.
	 */
	public static function field(session:TypingSession, className:String, name:String, isStatic:Bool,
			span:SourceSpan):Void {
		var found = classField(session, className, name, isStatic);
		if (found != null)
			requireField(session, found.declaration, found.field, span);
	}

	/** Source reaches `field` of `declaration`, found already (a write, which finds the field to check its property rules). */
	public static function requireField(session:TypingSession, declaration:AstClass, field:AstField,
			span:SourceSpan):Void
		require(session, {
			owner: declaration.name,
			name: field.name,
			isPublic: field.isPublic,
			ownerMetadata: declaration.metadata,
			metadata: field.metadata
		}, span);

	/**
	 * Source names the method `name` that `owner` declares (`owner.new` for a constructor): a call, a method value or `super`.
	 * `owner` is the declaring class, interface or abstract, as the method's lookup found it.
	 */
	public static function method(session:TypingSession, owner:String, name:String, span:SourceSpan):Void {
		var declared = session.signatures.get(owner + "." + name);
		if (declared == null)
			return;
		require(session, {
			owner: owner,
			name: name,
			isPublic: declared.isPublic,
			ownerMetadata: ownerMetadata(session, owner),
			metadata: declared.metadata
		}, span);
	}

	/** Requires that `member` may be reached from the code being typed. Visibility is not enforced yet: every member may. */
	static function require(session:TypingSession, member:DeclaredMember, span:SourceSpan):Void {}

	static function ownerMetadata(session:TypingSession, owner:String):Array<AstMetadata> {
		var classDecl = session.classDecls.get(owner);
		if (classDecl != null)
			return classDecl.metadata;
		var abstractDecl = session.declarations.abstractDeclaration(owner);
		return abstractDecl != null && abstractDecl.metadata != null ? abstractDecl.metadata : [];
	}

	/**
	 * Whether the code being typed may reach a private member `member` of `owner`, by Haxe's rules: inside `@:privateAccess`; in
	 * `owner` or a subclass of it; named by `@:allow` on `owner` or on the member; or reaching `owner` (or the member) by `@:access`
	 * on its class or its method.
	 */
	public static function canAccess(session:TypingSession, owner:String, ownerMetadata:Array<AstMetadata>,
			member:String,
			memberMetadata:Null<Array<AstMetadata>>):Bool {
		if (session.currentContext.privateAccessDepth > 0)
			return true;
		var caller = session.currentContext.lexicalOwner;
		var current = caller, seen:Map<String, Bool> = [];
		while (current != null) {
			if (seen.exists(current))
				throw 'Cyclic class hierarchy while checking access from "$caller"';
			seen.set(current, true);
			if (current == owner)
				return true;
			var declaration = session.classDecls.get(current);
			current = declaration == null || declaration.base == null ? null : baseName(declaration.base);
		}
		var functionName = session.currentContext.sourceFunctionName;
		return caller != null
			&& (grants(ownerMetadata, "allow", caller, functionName)
			|| memberMetadata != null && grants(memberMetadata, "allow", caller, functionName)
			|| hasAccess(session, caller, owner, member));
	}

	static function hasAccess(session:TypingSession, caller:String, owner:String, member:String):Bool {
		var declaration = session.classDecls.get(caller);
		if (declaration == null)
			return false;
		if (grants(declaration.metadata, "access", owner, owner + "." + member))
			return true;
		for (method in declaration.methods) {
			var name = method.name.indexOf(".") >= 0 ? method.name : caller + "." + method.name;
			if (name == session.currentContext.sourceFunctionName
				&& method.metadata != null
				&& grants(method.metadata, "access", owner, owner + "." + member))
				return true;
		}
		return false;
	}

	static function grants(metadata:Array<AstMetadata>, kind:String, caller:String, functionName:String):Bool {
		for (entry in metadata)
			if (entry.name == kind)
				for (argument in entry.arguments) {
					var path = expressionPath(argument);
					if (path != null
						&& (caller == path || functionName == path || StringTools.startsWith(caller, path + ".")))
						return true;
				}
		return false;
	}

	static function expressionPath(expression:AstExpression):Null<String>
		return switch expression {
			case Variable(name, _): name;
			case Member(object, name, _):
				var prefix = expressionPath(object);
				prefix == null ? null : prefix + "." + name;
			default: null;
		};

	static function baseName(type:AstType):Null<String>
		return switch type {
			case NamedType(name), AppliedType(name, _): name;
			default: null;
		};
}
