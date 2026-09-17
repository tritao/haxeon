package compiler.syntax;

import compiler.syntax.Ast.AstProgram;
import compiler.syntax.Ast.AstClass;
import compiler.syntax.Ast.AstType;
import compiler.syntax.SyntaxTree.SyntaxKind;
import compiler.syntax.SyntaxTree.SyntaxNode;
import compiler.syntax.SyntaxTree.SyntaxNodePayload;
import compiler.syntax.SyntaxTree.SyntaxTree;

/**
	Transition boundary from parser syntax to the compiler AST.

	The parser still owns AST construction while the CST grammar coverage is
	being completed. This boundary deliberately does not reparse source or keep
	AST references in syntax nodes. It validates the syntax outline against the
	direct AST and independently lowers the source header for the current
	transition.
	Once all AST-producing parser actions have syntax payloads, this is the only
	class that needs to change to construct AstProgram from CST nodes directly.
*/
class AstLowerer {
	public static function lower(tree:SyntaxTree, direct:AstProgram):AstProgram {
		validateSpans(tree);
		validateDeclarations(tree, direct);
		return lowerHeader(tree, direct);
	}

	/**
		Lower the source header from CST payloads. Declaration and body fields stay
		on the direct AST until their syntax payloads are complete, so this first
		step exercises an independent lowering path without reparsing.
	*/
	static function lowerHeader(tree:SyntaxTree, direct:AstProgram):AstProgram {
		var packageName:Null<String> = null,
			imports:Array<String> = [],
			importAliases:Map<String, String> = [];
		for (node in tree.grammarNodes())
			switch node.payload {
				case SyntaxNodePayload.PackageName(value):
					packageName = value;
				case SyntaxNodePayload.Import(path, alias):
					imports.push(path);
					if (alias != null)
						importAliases.set(alias, path);
				case SyntaxNodePayload.ClassHeader(_, _, _, _, _, _):
				case null:
			}
		if (packageName == null && direct.packageName != null)
			throw "CST/AST lowering lost the package declaration";
		if (imports.length != direct.imports.length)
			throw 'CST/AST lowering lost imports: expected ${direct.imports.length}, got ${imports.length}';
		for (index in 0...imports.length)
			if (imports[index] != direct.imports[index])
				throw 'CST/AST lowering changed import ${direct.imports[index]}';
		var directAliasCount = 0;
		for (alias in direct.importAliases.keys()) {
			directAliasCount++;
			if (!importAliases.exists(alias) || importAliases.get(alias) != direct.importAliases.get(alias))
				throw 'CST/AST lowering changed import alias $alias';
		}
		var loweredAliasCount = 0;
		for (_ in importAliases.keys())
			loweredAliasCount++;
		if (loweredAliasCount != directAliasCount)
			throw "CST/AST lowering changed import alias count";
		return {
			packageName: packageName,
			imports: imports,
			importAliases: importAliases,
			aliases: direct.aliases,
			enums: direct.enums,
			enumAbstracts: direct.enumAbstracts,
			abstracts: direct.abstracts,
			interfaces: direct.interfaces,
			classes: lowerClasses(tree, direct.classes),
			functions: direct.functions
		};
	}

	static function lowerClasses(tree:SyntaxTree, direct:Array<AstClass>):Array<AstClass> {
		var headers:Map<Int, {name:String, isPrivate:Bool, isExtern:Bool, typeParameters:Array<String>, baseName:Null<String>, interfaceNames:Array<Null<String>>}> = [];
		for (node in tree.grammarNodes())
			switch node.payload {
				case SyntaxNodePayload.ClassHeader(name, isPrivate, isExtern, typeParameters, baseName, interfaceNames):
					headers.set(node.span.start, {
						name: name,
						isPrivate: isPrivate,
						isExtern: isExtern,
						typeParameters: typeParameters,
						baseName: baseName,
						interfaceNames: interfaceNames
					});
				case SyntaxNodePayload.PackageName(_), SyntaxNodePayload.Import(_, _), null:
			}
		var result:Array<AstClass> = [];
		for (classDeclaration in direct) {
			var header = headers.get(classDeclaration.span.start);
			if (header == null || !isLowerableClass(classDeclaration, header)) {
				result.push(classDeclaration);
				continue;
			}
			result.push({
				name: header.name,
				isExtern: header.isExtern,
				typeParameters: header.typeParameters,
				typeConstraints: [],
				isPrivate: header.isPrivate,
				metadata: [],
				base: header.baseName == null ? null : NamedType(header.baseName),
				interfaces: [for (interfaceName in header.interfaceNames) NamedType(interfaceName)],
				fields: [],
				methods: [],
				span: classDeclaration.span
			});
		}
		return result;
	}

	static function isLowerableClass(classDeclaration:AstClass,
			header:{name:String, isPrivate:Bool, isExtern:Bool, typeParameters:Array<String>, baseName:Null<String>, interfaceNames:Array<Null<String>>}):Bool {
		if (classDeclaration.typeParameters.length != header.typeParameters.length
			|| (classDeclaration.typeConstraints != null && classDeclaration.typeConstraints.length > 0)
			|| classDeclaration.metadata.length > 0
			|| classDeclaration.fields.length > 0
			|| classDeclaration.methods.length > 0
			|| !simpleTypeMatches(classDeclaration.base, header.baseName)
			|| classDeclaration.interfaces.length != header.interfaceNames.length)
			return false;
		for (index in 0...classDeclaration.typeParameters.length)
			if (classDeclaration.typeParameters[index] != header.typeParameters[index])
				return false;
		for (index in 0...classDeclaration.interfaces.length) {
			var interfaceName = header.interfaceNames[index];
			if (interfaceName == null || !simpleTypeMatches(classDeclaration.interfaces[index], interfaceName))
				return false;
		}
		return true;
	}

	static function simpleTypeMatches(type:Null<AstType>, name:Null<String>):Bool
		return switch type {
			case null: name == null;
			case NamedType(value): name == value;
			default: false;
		};

	static function validateSpans(tree:SyntaxTree):Void {
		for (node in tree.grammarNodes()) {
			if (node.span.file != tree.source || node.span.start < 0 || node.span.end < node.span.start
				|| node.span.end > tree.source.bytes.length)
				throw 'CST node ${node.kind} has an invalid source span';
		}
	}

	static function validateDeclarations(tree:SyntaxTree, program:AstProgram):Void {
		var nodes = tree.grammarNodes();
		if (program.packageName != null)
			requireNode(nodes, SyntaxKind.PackageDeclaration, 1, "package declaration");
		requireNode(nodes, SyntaxKind.ImportDeclaration, program.imports.length, "import declarations");
		requireNode(nodes, SyntaxKind.TypeAliasDeclaration, program.aliases.length, "type aliases");
		requireNode(nodes, SyntaxKind.EnumDeclaration, program.enums.length, "enum declarations");
		requireNode(nodes, SyntaxKind.EnumAbstractDeclaration, program.enumAbstracts.length, "enum abstract declarations");
		requireNode(nodes, SyntaxKind.AbstractDeclaration, program.abstracts.length, "abstract declarations");
		requireNode(nodes, SyntaxKind.InterfaceDeclaration, program.interfaces.length, "interface declarations");
		requireNode(nodes, SyntaxKind.ClassDeclaration, program.classes.length, "class declarations");
		requireNode(nodes, SyntaxKind.FunctionDeclaration, program.functions.length + methodCount(program), "function declarations");
	}

	static function methodCount(program:AstProgram):Int {
		var count = 0;
		for (classDeclaration in program.classes)
			count += classDeclaration.methods.length;
		for (interfaceDeclaration in program.interfaces)
			count += interfaceDeclaration.methods.length;
		for (abstractDeclaration in program.abstracts)
			count += abstractDeclaration.methods.length;
		return count;
	}

	static function requireNode(nodes:Array<SyntaxNode>, kind:SyntaxKind, expected:Int, label:String):Void {
		if (expected == 0)
			return;
		var actual = 0;
		for (node in nodes)
			if (node.kind == kind)
				actual++;
		if (actual < expected)
			throw 'CST/AST lowering mismatch for $label: expected at least $expected, got $actual';
	}
}
