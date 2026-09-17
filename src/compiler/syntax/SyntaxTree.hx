package compiler.syntax;

import compiler.Source.SourceFile;
import compiler.Source.SourceSpan;
import compiler.syntax.SyntaxScanner.LosslessToken;
import compiler.syntax.SyntaxScanner.SyntaxTokenKind;
import compiler.syntax.Token.TokenKind;

/** Parser construction modes. Normal compiler parsing remains AST-only. */
enum ParserMode {
	AstOnly;
	Cst(source:SourceFile);
}

/** Grammar-level node categories used by the optional tooling CST. */
enum SyntaxKind {
	SourceFile;
	PackageDeclaration;
	ImportDeclaration;
	TypeAliasDeclaration;
	EnumDeclaration;
	EnumAbstractDeclaration;
	AbstractDeclaration;
	InterfaceDeclaration;
	ClassDeclaration;
	FunctionDeclaration;
	FieldDeclaration;
	Block;
	ParameterList;
	ArgumentList;
	ParenthesizedExpression;
	ArrayLiteral;
	ObjectLiteral;
	MapLiteral;
	AnonymousType;
	CallExpression;
	MemberExpression;
	IndexExpression;
	TypeArgumentList;
	TypeParameterList;
	Error;
	Missing;
}

/** Source-only payload attached to grammar nodes that can already lower independently. */
enum SyntaxNodePayload {
	PackageName(value:String);
	Import(path:String, alias:Null<String>);
	ClassHeader(name:String, isPrivate:Bool, isExtern:Bool, typeParameters:Array<String>, baseName:Null<String>, interfaceNames:Array<Null<String>>);
}

/** Trivia categories retained by tooling mode. */
enum SyntaxTriviaKind {
	Whitespace;
	Newline;
	LineComment;
	BlockComment;
	DocComment;
	Directive;
	Unknown;
}

/** A source token in the immutable syntax representation. */
class SyntaxToken {
	public final kind:TokenKind;
	public final span:SourceSpan;
	public final synthetic:Bool;
	final syntheticText:Null<String>;

	public function new(kind:TokenKind, span:SourceSpan, synthetic:Bool = false, ?syntheticText:String) {
		this.kind = kind;
		this.span = span;
		this.synthetic = synthetic;
		this.syntheticText = syntheticText;
	}

	public var text(get, never):String;

	function get_text():String
		return syntheticText == null ? span.file.slice(span.start, span.end) : syntheticText;

	public static function missing(kind:TokenKind, file:SourceFile, offset:Int, ?text:String):SyntaxToken
		return new SyntaxToken(kind, file.span(offset, offset), true, text == null ? "" : text);
}

/** A source trivia item. Trivia always points at original source bytes. */
class SyntaxTrivia {
	public final kind:SyntaxTriviaKind;
	public final span:SourceSpan;

	public function new(kind:SyntaxTriviaKind, span:SourceSpan) {
		this.kind = kind;
		this.span = span;
	}

	public var text(get, never):String;

	function get_text():String
		return span.file.slice(span.start, span.end);
}

enum SyntaxElement {
	Token(value:SyntaxToken);
	Trivia(value:SyntaxTrivia);
	Node(value:SyntaxNode);
}

/** Immutable source node with exact leaves and parser-reported grammar children. */
class SyntaxNode {
	public final kind:SyntaxKind;
	public final span:SourceSpan;
	public final children:Array<SyntaxElement>;
	public final grammarChildren:Array<SyntaxNode>;
	public final payload:Null<SyntaxNodePayload>;

	public function new(kind:SyntaxKind, span:SourceSpan, children:Array<SyntaxElement>, ?grammarChildren:Array<SyntaxNode>,
			?payload:SyntaxNodePayload) {
		this.kind = kind;
		this.span = span;
		this.children = children.copy();
		this.grammarChildren = grammarChildren == null ? [] : grammarChildren.copy();
		this.payload = payload;
	}
}

/**
		Optional tooling syntax tree built from the shared scanner and parser.

		The root retains an exact source sequence while grammarChildren contains
		parser-reported structure. Keeping those views separate lets the formatter
		adopt grammar information without making compiler ASTs depend on the CST.
 */
class SyntaxTree {
	public final source:SourceFile;
	public final root:SyntaxNode;
	public final tokens:Array<SyntaxToken>;
	public final trivia:Array<SyntaxTrivia>;
	public final syntheticTokens:Array<SyntaxToken>;

	function new(source:SourceFile, root:SyntaxNode, tokens:Array<SyntaxToken>, trivia:Array<SyntaxTrivia>, syntheticTokens:Array<SyntaxToken>) {
		this.source = source;
		this.root = root;
		this.tokens = tokens.copy();
		this.trivia = trivia.copy();
		this.syntheticTokens = syntheticTokens.copy();
	}

	public static function fromSource(source:SourceFile):SyntaxTree {
		var children:Array<SyntaxElement> = [], tokens:Array<SyntaxToken> = [], trivia:Array<SyntaxTrivia> = [];
		for (lossless in new SyntaxScanner(source).scan())
			switch lossless.kind {
				case SyntaxTokenKind.Syntax(kind):
					var token = new SyntaxToken(kind, lossless.span);
					tokens.push(token);
					children.push(SyntaxElement.Token(token));
				case SyntaxTokenKind.Whitespace:
					appendTrivia(children, trivia, SyntaxTriviaKind.Whitespace, lossless);
				case SyntaxTokenKind.Newline:
					appendTrivia(children, trivia, SyntaxTriviaKind.Newline, lossless);
				case SyntaxTokenKind.LineComment:
					appendTrivia(children, trivia, SyntaxTriviaKind.LineComment, lossless);
				case SyntaxTokenKind.BlockComment:
					appendTrivia(children, trivia, SyntaxTriviaKind.BlockComment, lossless);
				case SyntaxTokenKind.DocComment:
					appendTrivia(children, trivia, SyntaxTriviaKind.DocComment, lossless);
				case SyntaxTokenKind.Directive:
					appendTrivia(children, trivia, SyntaxTriviaKind.Directive, lossless);
				case SyntaxTokenKind.Unknown:
					appendTrivia(children, trivia, SyntaxTriviaKind.Unknown, lossless);
			}
		var span = source.span(0, source.bytes.length),
			root = new SyntaxNode(SyntaxKind.SourceFile, span, children);
		return new SyntaxTree(source, root, tokens, trivia, []);
	}

	/** Adds zero-width recovery tokens without changing source round-tripping. */
	public function withSyntheticTokens(values:Array<SyntaxToken>):SyntaxTree {
		if (values.length == 0)
			return this;
		var children = root.children.copy(),
			ordered = values.copy();
		ordered.sort(function(left, right) return left.span.start - right.span.start);
		for (value in ordered) {
			var insertion = 0;
			while (insertion < children.length && elementOffset(children[insertion]) < value.span.start)
				insertion++;
			children.insert(insertion, SyntaxElement.Token(value));
		}
		var synthetic = syntheticTokens.copy();
		synthetic = synthetic.concat(ordered);
		return new SyntaxTree(source, new SyntaxNode(root.kind, root.span, children, root.grammarChildren), tokens, trivia, synthetic);
	}

	/** Attaches parser-reported grammar nodes while retaining the source leaves. */
	public function withGrammarRoots(roots:Array<SyntaxNode>):SyntaxTree {
		return new SyntaxTree(source, new SyntaxNode(root.kind, root.span, root.children, roots), tokens, trivia, syntheticTokens);
	}

	/** Returns parser-reported grammar nodes in source order. */
	public function grammarNodes():Array<SyntaxNode> {
		var result:Array<SyntaxNode> = [];
		for (node in root.grammarChildren)
			appendGrammarNodes(node, result);
		return result;
	}

	/** Reconstructs the original source, excluding only future synthetic nodes. */
	public function roundTrip():String {
		var output = new StringBuf();
		for (child in root.children)
			switch child {
				case SyntaxElement.Token(token):
					if (!token.synthetic)
						output.add(token.text);
				case SyntaxElement.Trivia(value): output.add(value.text);
				case SyntaxElement.Node(node): output.add(nodeText(node));
			}
		return output.toString();
	}

	static function appendTrivia(children:Array<SyntaxElement>, trivia:Array<SyntaxTrivia>, kind:SyntaxTriviaKind, lossless:LosslessToken):Void {
		var value = new SyntaxTrivia(kind, lossless.span);
		trivia.push(value);
		children.push(SyntaxElement.Trivia(value));
	}

	static function elementOffset(element:SyntaxElement):Int
		return switch element {
			case SyntaxElement.Token(token): token.span.start;
			case SyntaxElement.Trivia(value): value.span.start;
			case SyntaxElement.Node(node): node.span.start;
		};

	static function nodeText(node:SyntaxNode):String {
		var output = new StringBuf();
		for (child in node.children)
			switch child {
				case SyntaxElement.Token(token):
					if (!token.synthetic)
						output.add(token.text);
				case SyntaxElement.Trivia(value): output.add(value.text);
				case SyntaxElement.Node(value): output.add(nodeText(value));
			}
		return output.toString();
	}

	static function appendGrammarNodes(node:SyntaxNode, result:Array<SyntaxNode>):Void {
		result.push(node);
		for (child in node.grammarChildren)
			appendGrammarNodes(child, result);
	}
}
