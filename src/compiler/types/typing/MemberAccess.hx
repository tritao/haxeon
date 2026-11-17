package compiler.types.typing;

import compiler.core.Diagnostic;
import compiler.core.Diagnostic.CompileError;
import compiler.core.InternalError;
import compiler.core.Source.SourceSpan;
import compiler.semantic.ModuleFields;
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

	/** Where it is declared: a module-level variable is visible to its whole module, which is its source file. */
	final declaredIn:SourceSpan;

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
	/**
	 * The field `name` of class `className`: an instance field of it or of the nearest base class declaring it, or a static field of
	 * `className` itself (statics are not inherited, as in Haxe).
	 */
	public static function classField(session:TypingSession, className:String, name:String,
			isStatic:Bool):Null<DeclaredField> {
		var owner:Null<String> = className, seen:Map<String, Bool> = [];
		while (owner != null) {
			if (seen.exists(owner))
				throw new InternalError('Cyclic class hierarchy while resolving "$className.$name"');
			seen.set(owner, true);
			var declaration = session.classDecls.get(owner);
			if (declaration == null)
				return null;
			for (field in declaration.fields)
				if (field.name == name && field.isStatic == isStatic)
					return {declaration: declaration, field: field};
			// A static belongs to the class that declares it: a subclass neither inherits it nor names it.
			if (isStatic)
				return null;
			owner = declaration.base == null ? null : baseName(declaration.base);
		}
		return null;
	}

	/**
	 * The method `name` of `className`: its own, or an instance method of its base classes or (for an interface) its base
	 * interfaces, first found first. A static method is `className`'s own only: statics are not inherited, as in Haxe, so
	 * `Derived.make()` and a bare `make()` inside Derived do not reach Base's static `make`.
	 */
	public static function methodInfo(session:TypingSession, className:String, name:String):Null<SemanticMethodInfo> {
		var results:Array<SemanticMethodInfo> = [];
		findMethods(session, className, name, results);
		return results.length == 0 || results[0].isStatic && results[0].owner != className ? null : results[0];
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
			declaredIn: field.span,
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
			isPublic: declared.isPublic == null && declared.isOverride == true ? overriddenVisibility(session, owner,
				name) : declared.isPublic,
			declaredIn: declared.span,
			ownerMetadata: ownerMetadata(session, owner),
			metadata: declared.metadata
		}, span);
	}

	/**
	 * Requires that `member` may be reached from the code being typed (`E1030`, worded as Haxe words it): it is public, or the code
	 * may reach a private member of its owner (`canAccess`), or it is a module-level variable read in its own module.
	 */
	static function require(session:TypingSession, member:DeclaredMember, span:SourceSpan):Void {
		if (isPublic(session, member)
			|| canAccess(session, member.owner, member.ownerMetadata, member.name, member.metadata)
			|| StringTools.endsWith(member.owner, ModuleFields.storageName(""))
			&& span.file.path == member.declaredIn.file.path)
			return;
		throw new CompileError(new Diagnostic("E1030", member.name == "new"
			? 'Cannot access private constructor of ${member.owner}' : 'Cannot access private field ${member.name}',
			span));
	}

	/**
	 * Whether `member` is public, by Haxe's rule: as written, or with no modifier, when its owner is an interface, an extern
	 * class, or a class with `@:publicFields`; a class's or abstract's member is private otherwise.
	 */
	static function isPublic(session:TypingSession, member:DeclaredMember):Bool {
		if (member.isPublic != null)
			return member.isPublic;
		if (session.interfaceDecls.exists(member.owner))
			return true;
		var classDecl = session.classDecls.get(member.owner);
		if (classDecl != null && classDecl.isExtern == true)
			return true;
		var abstractDecl = session.declarations.abstractDeclaration(member.owner);
		if (abstractDecl != null && abstractDecl.isExtern == true)
			return true;
		for (entry in member.ownerMetadata)
			if (entry.name == "publicFields")
				return true;
		return false;
	}

	/**
	 * An override written without a modifier has the visibility of the method it overrides, as in Haxe. One that overrides
	 * nothing is a broken declaration, which the inherited-method check reports (`E1020`); it is not reported again here.
	 */
	static function overriddenVisibility(session:TypingSession, owner:String, name:String):Bool {
		var classDecl = session.classDecls.get(owner);
		var current = classDecl == null || classDecl.base == null ? null : baseName(classDecl.base),
			seen:Map<String, Bool> = [];
		while (current != null && !seen.exists(current)) {
			seen.set(current, true);
			var declared = session.signatures.get(current + "." + name);
			if (declared != null && (declared.isPublic != null || declared.isOverride != true))
				return declared.isPublic == true;
			var base = session.classDecls.get(current);
			current = base == null || base.base == null ? null : baseName(base.base);
		}
		return true;
	}

	/**
	 * Types `read` without requiring access again: it reaches members that source named where they were already allowed (a known
	 * key path's fields, read where the path is used), or that belong to the declaration being typed (an enum abstract value's
	 * initializer, typed where a value is first used). Not for code the user wrote here.
	 */
	public static function allowed<T>(session:TypingSession, read:() -> T):T {
		var context = session.currentContext;
		context.privateAccessDepth++;
		try {
			var result = read();
			context.privateAccessDepth--;
			return result;
		} catch (error:haxe.Exception) {
			context.privateAccessDepth--;
			throw error;
		}
	}

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
				throw new InternalError('Cyclic class hierarchy while checking access from "$caller"');
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
