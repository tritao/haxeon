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
	Metadata;
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
	BinaryExpression;
	ConditionalExpression;
	AssignmentExpression;
	TypeArgumentList;
	TypeParameterList;
	VariableDeclaration;
	AssignmentStatement;
	ThrowStatement;
	TryStatement;
	SwitchStatement;
	IncrementStatement;
	ExpressionStatement;
	ReturnStatement;
	BreakStatement;
	ContinueStatement;
	IfStatement;
	WhileStatement;
	DoWhileStatement;
	ForStatement;
	Error;
	Missing;
}

typedef SyntaxFunctionParameter = {
	final name:String;
	final typeName:Null<String>;
	final optional:Bool;
}

enum SyntaxBinaryOperator {
	Add;
	Sub;
	Mul;
	Div;
	Mod;
	BitAnd;
	BitXor;
	BitOr;
	ShiftLeft;
	ShiftRight;
	UnsignedShiftRight;
	Less;
	LessEqual;
	Greater;
	GreaterEqual;
	Equal;
	NotEqual;
	And;
	Or;
}

enum SyntaxUnaryOperator {
	Negate;
	Not;
}

enum SyntaxNativeLayoutQueryKind {
	SizeOf;
	AlignOf;
	OffsetOf;
}

enum SyntaxTypePayload {
	IntType;
	BoolType;
	FloatType;
	StringType;
	VoidType;
	InferredType;
	ErrorType;
	NativeAbstractType(declaration:String, tag:String);
	NamedType(name:String);
	AppliedType(name:String, arguments:Array<SyntaxTypePayload>);
	ArrayType(element:SyntaxTypePayload);
	MapType(key:SyntaxTypePayload, value:SyntaxTypePayload);
	NullableType(element:SyntaxTypePayload);
	FunctionType(arguments:Array<SyntaxTypePayload>, result:SyntaxTypePayload);
	AnonymousType(fields:Array<SyntaxAnonymousFieldPayload>);
}

typedef SyntaxAnonymousFieldPayload = {
	final name:String;
	final type:SyntaxTypePayload;
	final optional:Bool;
	final span:SourceSpan;
}

typedef SyntaxArgumentPayload = {
	final name:String;
	final type:SyntaxTypePayload;
	final optional:Bool;
	final defaultValue:Null<SyntaxExpressionPayload>;
}

typedef SyntaxTypeConstraintPayload = {
	final parameter:String;
	final type:SyntaxTypePayload;
}

typedef SyntaxObjectFieldPayload = {
	final name:String;
	final value:SyntaxExpressionPayload;
}

typedef SyntaxMapEntryPayload = {
	final key:SyntaxExpressionPayload;
	final value:SyntaxExpressionPayload;
}

typedef SyntaxSwitchExpressionCasePayload = {
	final value:SyntaxExpressionPayload;
	final guard:Null<SyntaxExpressionPayload>;
	final result:SyntaxExpressionPayload;
}

typedef SyntaxSwitchCasePayload = {
	final value:SyntaxExpressionPayload;
	final guard:Null<SyntaxExpressionPayload>;
	final statements:Array<SyntaxStatementPayload>;
}

typedef SyntaxCatchPayload = {
	final name:String;
	final type:SyntaxTypePayload;
	final statements:Array<SyntaxStatementPayload>;
}

typedef SyntaxEnumParameterPayload = {
	final name:Null<String>;
	final type:SyntaxTypePayload;
	final optional:Bool;
}

typedef SyntaxEnumCasePayload = {
	final name:String;
	final parameters:Array<SyntaxEnumParameterPayload>;
}

typedef SyntaxEnumValuePayload = {
	final name:String;
	final value:SyntaxExpressionPayload;
}

enum SyntaxExpressionPayload {
	Integer(value:Int);
	Float(value:Float);
	String(value:String);
	Bool(value:Bool);
	NullValue;
	Unreachable;
	Empty;
	Error;
	Variable(name:String);
	Member(object:SyntaxExpressionPayload, name:String);
	Binary(operation:SyntaxBinaryOperator, left:SyntaxExpressionPayload, right:SyntaxExpressionPayload);
	Unary(operation:SyntaxUnaryOperator, value:SyntaxExpressionPayload);
	Conditional(condition:SyntaxExpressionPayload, whenTrue:SyntaxExpressionPayload, whenFalse:SyntaxExpressionPayload);
	Block(statements:Array<SyntaxStatementPayload>, result:SyntaxExpressionPayload);
	Throw(value:SyntaxExpressionPayload);
	Cast(value:SyntaxExpressionPayload, target:Null<SyntaxTypePayload>);
	Switch(value:SyntaxExpressionPayload, cases:Array<SyntaxSwitchExpressionCasePayload>, defaultValue:Null<SyntaxExpressionPayload>);
	Object(fields:Array<SyntaxObjectFieldPayload>);
	Array(values:Array<SyntaxExpressionPayload>);
	Map(entries:Array<SyntaxMapEntryPayload>);
	ArrayComprehension(keyName:String, valueName:Null<String>, iterable:SyntaxExpressionPayload,
		condition:Null<SyntaxExpressionPayload>, value:SyntaxExpressionPayload);
	MapComprehension(keyName:String, valueName:Null<String>, iterable:SyntaxExpressionPayload,
		condition:Null<SyntaxExpressionPayload>, key:SyntaxExpressionPayload, value:SyntaxExpressionPayload);
	Range(start:SyntaxExpressionPayload, end:SyntaxExpressionPayload);
	Call(name:String, arguments:Array<SyntaxExpressionPayload>);
	NativeLayoutQuery(kind:SyntaxNativeLayoutQueryKind, type:SyntaxTypePayload, field:Null<String>);
	ClosureCall(callee:SyntaxExpressionPayload, arguments:Array<SyntaxExpressionPayload>);
	MethodCall(object:SyntaxExpressionPayload, name:String, arguments:Array<SyntaxExpressionPayload>);
	New(typeName:String, arguments:Array<SyntaxExpressionPayload>);
	NewGeneric(typeName:String, typeArguments:Array<SyntaxTypePayload>, arguments:Array<SyntaxExpressionPayload>);
	NewArray(element:SyntaxTypePayload, length:SyntaxExpressionPayload);
	NewMap(key:SyntaxTypePayload, value:SyntaxTypePayload);
	Index(array:SyntaxExpressionPayload, index:SyntaxExpressionPayload);
	PostfixIncrement(target:SyntaxExpressionPayload, delta:Int);
	Lambda(arguments:Array<SyntaxArgumentPayload>, statements:Array<SyntaxStatementPayload>);
}

enum SyntaxStatementPayload {
	Error;
	UninitializedDeclaration(name:String, type:SyntaxTypePayload);
	VarDeclaration(name:String, type:Null<SyntaxTypePayload>, initializer:SyntaxExpressionPayload);
	Assignment(name:String, expression:SyntaxExpressionPayload);
	IndexAssignment(array:SyntaxExpressionPayload, index:SyntaxExpressionPayload, expression:SyntaxExpressionPayload);
	FieldAssignment(object:SyntaxExpressionPayload, field:String, expression:SyntaxExpressionPayload);
	Break;
	Continue;
	ReturnVoid;
	Return(value:SyntaxExpressionPayload);
	Throw(value:SyntaxExpressionPayload);
	Try(tryBranch:Array<SyntaxStatementPayload>, catches:Array<SyntaxCatchPayload>);
	IfBranch(condition:SyntaxExpressionPayload, thenBranch:Array<SyntaxStatementPayload>, elseBranch:Array<SyntaxStatementPayload>);
	WhileLoop(condition:SyntaxExpressionPayload, body:Array<SyntaxStatementPayload>);
	DoWhileLoop(body:Array<SyntaxStatementPayload>, condition:SyntaxExpressionPayload);
	ForLoop(keyName:String, valueName:Null<String>, iterable:SyntaxExpressionPayload, body:Array<SyntaxStatementPayload>);
	Switch(expression:SyntaxExpressionPayload, cases:Array<SyntaxSwitchCasePayload>, defaultBranch:Array<SyntaxStatementPayload>, hasDefault:Bool);
	Increment(name:String, delta:Int);
	Expression(value:SyntaxExpressionPayload);
}

/** Source-only payload attached to grammar nodes that can already lower independently. */
enum SyntaxNodePayload {
	PackageName(value:String);
	Import(path:String, alias:Null<String>);
	Metadata(name:String, arguments:Array<SyntaxExpressionPayload>);
	ClassHeader(name:String, isPrivate:Bool, isExtern:Bool, typeParameters:Array<String>, baseName:Null<String>, interfaceNames:Array<Null<String>>);
	ClassHeaderRich(name:String, isPrivate:Bool, isExtern:Bool, typeParameters:Array<String>, typeConstraints:Array<SyntaxTypeConstraintPayload>, baseType:Null<SyntaxTypePayload>, interfaceTypes:Array<SyntaxTypePayload>);
	FieldHeader(name:String, typeName:Null<String>, isStatic:Bool, isInline:Bool, isFinal:Bool, readAccess:Null<String>, writeAccess:Null<String>);
	FieldHeaderRich(name:String, type:Null<SyntaxTypePayload>, initializer:Null<SyntaxExpressionPayload>, isStatic:Bool, isInline:Bool, isFinal:Bool, readAccess:Null<String>, writeAccess:Null<String>);
	FunctionHeader(name:String, isStatic:Bool, isExtern:Bool, typeParameters:Array<String>, parameters:Array<SyntaxFunctionParameter>, resultTypeName:Null<String>);
	FunctionHeaderRich(name:String, isStatic:Bool, isExtern:Bool, typeParameters:Array<String>, typeConstraints:Array<SyntaxTypeConstraintPayload>, parameters:Array<SyntaxArgumentPayload>, resultType:SyntaxTypePayload);
	Statement(value:SyntaxStatementPayload);
	TypeAliasHeader(name:String, isPrivate:Bool, typeParameters:Array<String>, typeConstraints:Array<SyntaxTypeConstraintPayload>, type:SyntaxTypePayload);
	EnumHeader(name:String, typeParameters:Array<String>, typeConstraints:Array<SyntaxTypeConstraintPayload>, cases:Array<SyntaxEnumCasePayload>);
	EnumAbstractHeader(name:String, underlying:SyntaxTypePayload, fromTypes:Array<SyntaxTypePayload>, toTypes:Array<SyntaxTypePayload>, values:Array<SyntaxEnumValuePayload>);
	AbstractHeader(name:String, isExtern:Bool, typeParameters:Array<String>, typeConstraints:Array<SyntaxTypeConstraintPayload>, underlying:SyntaxTypePayload, fromTypes:Array<SyntaxTypePayload>, toTypes:Array<SyntaxTypePayload>);
	InterfaceHeader(name:String, typeParameters:Array<String>, typeConstraints:Array<SyntaxTypeConstraintPayload>, bases:Array<SyntaxTypePayload>);
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
			?payload:SyntaxNodePayload, copyArrays:Bool = true) {
		this.kind = kind;
		this.span = span;
		this.children = copyArrays ? children.copy() : children;
		this.grammarChildren = grammarChildren == null ? [] : copyArrays ? grammarChildren.copy() : grammarChildren;
		this.payload = payload;
	}

	/** Constructs a node from arrays owned exclusively by the syntax tree. */
	public static function fromOwned(kind:SyntaxKind, span:SourceSpan, children:Array<SyntaxElement>,
			grammarChildren:Array<SyntaxNode>, ?payload:SyntaxNodePayload):SyntaxNode
		return new SyntaxNode(kind, span, children, grammarChildren, payload, false);
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
	var cachedGrammarNodes:Null<Array<SyntaxNode>>;
	var cachedPayloads:Null<Map<Int, SyntaxNodePayload>>;

	function new(source:SourceFile, root:SyntaxNode, tokens:Array<SyntaxToken>, trivia:Array<SyntaxTrivia>, syntheticTokens:Array<SyntaxToken>, copyArrays:Bool = true) {
		this.source = source;
		this.root = root;
		this.tokens = copyArrays ? tokens.copy() : tokens;
		this.trivia = copyArrays ? trivia.copy() : trivia;
		this.syntheticTokens = copyArrays ? syntheticTokens.copy() : syntheticTokens;
	}

	static function fromOwned(source:SourceFile, root:SyntaxNode, tokens:Array<SyntaxToken>, trivia:Array<SyntaxTrivia>, syntheticTokens:Array<SyntaxToken>):SyntaxTree
		return new SyntaxTree(source, root, tokens, trivia, syntheticTokens, false);

	public static function fromSource(source:SourceFile):SyntaxTree {
		return fromLossless(source, new SyntaxScanner(source).scan());
	}

	/** Builds the source leaves from an already completed lossless scan. */
	public static function fromLossless(source:SourceFile, losslessTokens:Array<LosslessToken>):SyntaxTree {
		var children:Array<SyntaxElement> = [], tokens:Array<SyntaxToken> = [], trivia:Array<SyntaxTrivia> = [],
			childLength = 0, tokenLength = 0;
		children.resize(losslessTokens.length);
		tokens.resize(losslessTokens.length);
		for (lossless in losslessTokens)
			switch lossless.kind {
				case SyntaxTokenKind.Syntax(kind):
					var token = new SyntaxToken(kind, lossless.span);
					tokens[tokenLength++] = token;
					children[childLength++] = SyntaxElement.Token(token);
				case SyntaxTokenKind.Whitespace:
					children[childLength++] = appendTrivia(trivia, SyntaxTriviaKind.Whitespace, lossless);
				case SyntaxTokenKind.Newline:
					children[childLength++] = appendTrivia(trivia, SyntaxTriviaKind.Newline, lossless);
				case SyntaxTokenKind.LineComment:
					children[childLength++] = appendTrivia(trivia, SyntaxTriviaKind.LineComment, lossless);
				case SyntaxTokenKind.BlockComment:
					children[childLength++] = appendTrivia(trivia, SyntaxTriviaKind.BlockComment, lossless);
				case SyntaxTokenKind.DocComment:
					children[childLength++] = appendTrivia(trivia, SyntaxTriviaKind.DocComment, lossless);
				case SyntaxTokenKind.Directive:
					children[childLength++] = appendTrivia(trivia, SyntaxTriviaKind.Directive, lossless);
				case SyntaxTokenKind.Unknown:
					children[childLength++] = appendTrivia(trivia, SyntaxTriviaKind.Unknown, lossless);
			}
		children.resize(childLength);
		tokens.resize(tokenLength);
		var span = source.span(0, source.bytes.length),
			root = SyntaxNode.fromOwned(SyntaxKind.SourceFile, span, children, []);
		return fromOwned(source, root, tokens, trivia, []);
	}

	/** Adds zero-width recovery tokens without changing source round-tripping. */
	public function withSyntheticTokens(values:Array<SyntaxToken>):SyntaxTree {
		if (values.length == 0)
			return this;
		return withGrammarRootsAndSynthetic(root.grammarChildren, values);
	}

	/** Publishes grammar roots and synthetic recovery tokens in one owned tree view. */
	public function withGrammarRootsAndSynthetic(roots:Array<SyntaxNode>, values:Array<SyntaxToken>):SyntaxTree {
		if (values.length == 0)
			return fromOwned(source, SyntaxNode.fromOwned(root.kind, root.span, root.children, roots), tokens, trivia, syntheticTokens);
		var children = root.children.copy(),
			ordered = values.copy();
		if (ordered.length > 0) {
			ordered.sort(function(left, right) return left.span.start - right.span.start);
			for (value in ordered) {
				var insertion = 0;
				while (insertion < children.length && elementOffset(children[insertion]) < value.span.start)
					insertion++;
				children.insert(insertion, SyntaxElement.Token(value));
			}
		}
		return fromOwned(source, SyntaxNode.fromOwned(root.kind, root.span, children, roots), tokens, trivia, syntheticTokens.concat(ordered));
	}

	/** Attaches parser-reported grammar nodes while retaining the source leaves. */
	public function withGrammarRoots(roots:Array<SyntaxNode>):SyntaxTree {
		return fromOwned(source, SyntaxNode.fromOwned(root.kind, root.span, root.children, roots), tokens, trivia, syntheticTokens);
	}

	/** Returns parser-reported grammar nodes in source order. */
	public function grammarNodes():Array<SyntaxNode> {
		ensureGrammarIndexes();
		return cachedGrammarNodes;
	}

	/** Returns the cached source-payload lookup used by AST lowering. */
	public function payloadsByStart():Map<Int, SyntaxNodePayload> {
		ensureGrammarIndexes();
		return cachedPayloads;
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

	static function appendTrivia(trivia:Array<SyntaxTrivia>, kind:SyntaxTriviaKind, lossless:LosslessToken):SyntaxElement {
		var value = new SyntaxTrivia(kind, lossless.span);
		trivia.push(value);
		return SyntaxElement.Trivia(value);
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

	function ensureGrammarIndexes():Void {
		if (cachedGrammarNodes != null && cachedPayloads != null)
			return;
		var nodes:Array<SyntaxNode> = [], payloads:Map<Int, SyntaxNodePayload> = [];
		for (node in root.grammarChildren)
			appendGrammarIndexes(node, nodes, payloads);
		cachedGrammarNodes = nodes;
		cachedPayloads = payloads;
	}

	static function appendGrammarIndexes(node:SyntaxNode, nodes:Array<SyntaxNode>, payloads:Map<Int, SyntaxNodePayload>):Void {
		nodes.push(node);
		if (node.payload != null)
			payloads.set(node.span.start, node.payload);
		for (child in node.grammarChildren)
			appendGrammarIndexes(child, nodes, payloads);
	}
}
