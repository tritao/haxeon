package compiler.syntax;

import compiler.syntax.Ast.AstProgram;
import compiler.syntax.SyntaxTree.SyntaxKind;
import compiler.syntax.SyntaxTree.SyntaxNode;
import compiler.syntax.SyntaxTree.SyntaxTree;

/**
	Transition boundary from parser syntax to the compiler AST.

	The parser still owns AST construction while the CST grammar coverage is
	being completed. This boundary deliberately does not reparse source or keep
	AST references in syntax nodes. It validates the syntax outline against the
	direct AST and returns the same immutable program for the current transition.
	Once all AST-producing parser actions have syntax payloads, this is the only
	class that needs to change to construct AstProgram from CST nodes directly.
*/
class AstLowerer {
	public static function lower(tree:SyntaxTree, direct:AstProgram):AstProgram {
		validateSpans(tree);
		validateDeclarations(tree, direct);
		return direct;
	}

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
