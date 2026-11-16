import compiler.core.Source.SourceFile;
import compiler.formatter.FormatConfig.FormatConfigTools;
import compiler.formatter.FormatScanner;
import compiler.formatter.FormatToken.FormatTokenKind;
import compiler.formatter.Formatter;
import compiler.syntax.Lexer;
import compiler.syntax.Token.TokenKind;

class FormatterMain {
	static function assertTokenPreservation():Void {
		// A comment may move and its lines may be re-indented; its text may not change.
		compiler.formatter.TokenPreservation.verify("comments.hx", "var x = 1; // before\n", "// before\nvar x=1;\n");
		compiler.formatter.TokenPreservation.verify("comments.hx", "/**\n   * doc\n   */\nvar x = 1;\n",
			"/**\n * doc\n */\nvar x = 1;\n");
		var commentRefused = false;
		try {
			compiler.formatter.TokenPreservation.verify("comments.hx", "var x = 1; // before\n",
				"/* moved */\nvar x=1;\n");
		} catch (error:compiler.formatter.TokenPreservation.TokenMismatch) {
			commentRefused = error.message.indexOf("changed comment 1") >= 0;
		}
		if (!commentRefused)
			throw "Token guard accepted a changed comment";
		for (output in ["var x = a +++ b;", "var x = a + ++c;", "var x = a + ++b; extra;"]) {
			var refused = false;
			try {
				compiler.formatter.TokenPreservation.verify("known-bad.hx", "var x = a + ++b;", output);
			} catch (error:compiler.formatter.TokenPreservation.TokenMismatch) {
				refused = error.message.indexOf("known-bad.hx at token ") >= 0
					&& error.message.indexOf("expected ") >= 0
					&& error.message.indexOf("got ") >= 0;
			}
			if (!refused)
				throw "Token guard accepted corrupt output or omitted its first-token diagnostic";
		}
	}

	/** The scanner and the lexer must agree on every operator, or the formatter would split a token such as `??`. */
	static function assertScannerMatchesLexer(text:String):Void {
		var file = new SourceFile("operators.hx", text),
			tokens = new FormatScanner(file).scan(),
			lexical = new Lexer(file).tokenize(),
			index = 0;
		for (token in tokens)
			switch token.kind {
				case FormatTokenKind.Syntax(kind):
					if (lexical[index].kind != kind || lexical[index].text != token.text)
						throw 'scanner token "${token.text}" differs from lexer token "${lexical[index].text}"';
					index++;
				default:
			}
		if (lexical[index].kind != TokenKind.Eof)
			throw "scanner dropped tokens the lexer produced";
	}

	static function assertUpdateOperatorBoundaries():Void {
		for (expression in [
			"x + ++y",
			"x - --y",
			"x * ++y",
			"x / --y",
			"x - -y",
			"- -x",
			"++x + y",
			"x++ + y",
			"--x - y",
			"x-- - y"
		]) {
			var source = "function f(x:Int, y:Int):Int return " + expression + ";\n";
			for (width in [120, 24, 8]) {
				var config = FormatConfigTools.make(2, true);
				config.lineWidth = width;
				var output = Formatter.format(source, config);
				if (output == null)
					throw "Update operator source was rejected: " + expression;
				var before = new Lexer(new SourceFile("before.hx", source)).tokenize();
				var after = new Lexer(new SourceFile("after.hx", output)).tokenize();
				if (before.length != after.length)
					throw "Formatting changed update operator token count: " + expression;
				for (index in 0...before.length)
					if (before[index].kind != after[index].kind || before[index].text != after[index].text)
						throw "Formatting changed update operator tokens: " + expression;
				if (Formatter.format(output, config) != output)
					throw "Update operator formatting was not stable";
			}
		}
	}

	static function assertGenericAssignmentBoundaries():Void {
		for (width in [120, 24, 8]) {
			var config = FormatConfigTools.make(2, true);
			config.lineWidth = width;
			var source =
				"class Test { var a:Array<Int>=[]; var b:Map<String,Array<Int>>=new Map(); var c:Array<Int> = []; }\n";
			var output = Formatter.format(source, config);
			if (output == null)
				throw "Generic assignment source was rejected";
			var before = new Lexer(new SourceFile("before.hx", source)).tokenize();
			var after = new Lexer(new SourceFile("after.hx", output)).tokenize();
			if (before.length != after.length)
				throw "Generic assignment formatting changed token count at width " + width;
			for (index in 0...before.length)
				if (before[index].kind != after[index].kind || before[index].text != after[index].text)
					throw "Generic assignment formatting changed token " + index + " at width " + width;
			if (Formatter.format(output, config) != output)
				throw "Generic compound-token formatting was not stable";
		}
	}

	/** A comment that trails code stays on its line, the statement it trails keeps its continuation indent, and a second pass is a no-op. */
	static function assertTrailingComments():Void {
		var cases =
			["class A {\n\tfunction f() {\n\t\tvar first = 1, // a comment long enough to push this line well beyond the column limit of the formatter, surely\n\t\t\tsecond = 2;\n\t}\n}\n",
		// A comment inside an argument list puts each argument on its own line, rather than leaving the list half-flat.
		"class A {\n\tfunction f() {\n\t\tfoo(\n\t\t\ta, // x\n\t\t\tb\n\t\t);\n\t}\n}\n",
			"class A {\n\tfunction f() {\n\t\tvar x = 1; // after a statement\n\t\ty();\n\t}\n}\n"];
		for (source in cases) {
			var once = Formatter.format(source, FormatConfigTools.make(4, false));
			if (once != source)
				throw 'Trailing comment layout changed:\n$source\nbecame\n$once';
		}
	}

	/** A script's `#!` first line is kept as it is, and the code after it is formatted as usual. */
	static function assertShebang():Void {
		var source = "#!/usr/bin/env haxeon\nfunction main() {\n\tSys.println(\"script\");\n}\n",
			once = Formatter.format(source, FormatConfigTools.make(4, false));
		if (once != source)
			throw 'A leading #! line changed:\n$source\nbecame\n$once';
		var spaced = Formatter.format("#!/usr/bin/env haxeon\nfunction main(){Sys.println(1);}\n",
			FormatConfigTools.make(4, false));
		if (!StringTools.startsWith(spaced, "#!/usr/bin/env haxeon\nfunction main() {"))
			throw 'Code after a #! line was not formatted:\n$spaced';
	}

	/** Valid Haxe that Haxeon's parser does not accept yet is formatted; unbalanced brackets are still refused. */
	static function assertBeyondParser():Void {
		for (source in [
			"using StringTools;\nclass A {}\n",
			"package;\nclass A {}\n",
			"class A {\n\tstatic function f(...parts:String) {}\n}\n",
			"class A {\n\tfunction f() {\n\t\ttry {} catch (_) {}\n\t}\n}\n"
		])
			if (Formatter.format(source, FormatConfigTools.make(4, false)) == null)
				throw 'Formatter refused valid Haxe:\n$source';
	}

	/** `@formatter:off` with no `@formatter:on` keeps the rest of the file as written, without doubling its last newline. */
	static function assertOpenFormatterOff():Void {
		var source =
			"class Probe { // @formatter:off: a test addresses this file by line\nfunction   f() {return 1;}\n}\n";
		if (Formatter.format(source, FormatConfigTools.make(4, false)) != source)
			throw "An open @formatter:off range did not keep the rest of the file";
	}

	/**
	 * Layout rules that match how this code is written: bodies on their own line, `{}` kept, types read whole, filled argument lists,
	 * and the author's one-per-line literals and declarations kept. Each case is already formatted, so formatting changes nothing.
	 */
	static function assertHouseLayout():Void {
		var config = FormatConfigTools.make(4, false);
		for (source in [
			"class A {\n\tfunction f() {\n\t\tif (a)\n\t\t\tx();\n\t\telse if (b)\n\t\t\ty();\n\t\telse\n\t\t\tz();\n\t\tfor (i in 0...3)\n\t\t\tfor (j in 0...3) {\n\t\t\t\tk(i, j);\n\t\t\t}\n\t\tvar v = if (a) 1 else 2;\n\t\tdo {\n\t\t\tx();\n\t\t} while (c);\n\t}\n}\n",
			"class A {\n\tpublic function new() {}\n\n\tfunction f() {\n\t\tif (a) {}\n\t\tswitch x {}\n\t\ttry {} catch (e:Dynamic) {}\n\t}\n}\n",
			"class A {\n\tfunction f() {\n\t\tvar a = 1, b = 2;\n\t\tvar objects:Map<String, Int> = [],\n\t\t\tsubclasses:Map<String, Array<String>> = [];\n\t\tvar values = [\n\t\t\tfirst,\n\t\t\tsecond\n\t\t];\n\t\tvar flat = {x: 1, y: 2};\n\t\tvar order = [for (_ in 0...count) -1];\n\t\tvar t = a ? b : c, typed:Array<Int> = [];\n\t}\n}\n"
		]) {
			var formatted = Formatter.format(source, config);
			if (formatted != source)
				throw 'Formatting changed already formatted code:\n$source\nbecame\n$formatted';
		}
	}

	static function main():Void {
		assertTokenPreservation();
		assertHouseLayout();
		assertOpenFormatterOff();
		assertTrailingComments();
		assertShebang();
		assertBeyondParser();
		assertGenericAssignmentBoundaries();
		assertUpdateOperatorBoundaries();
		assertScannerMatchesLexer("function main():Int { var a = b ?? c; a += 1; a -= 1; a *= 2; a /= 2; a %= 2; a &= 1; a |= 1; a ^= 1; a++; --a; "
			+ "var t = a == b || a != b && a <= b || a >= b; var f = (x) -> x; var u = !a; var v = ~a; var w = [a ? b : c]; "
			+ "var s = (a << 1) | (a >> 1) & (a >>> 1); var q:Map<String, Array<Int>> = []; @:meta var m = a.b; $a; return a < b ? 1 : a > b ? 2 : 3; }");
		var source =
			"function main():Int {\nvar text = \"{ literal }\"; // }\n/* keep { } */\nif (true) {\nreturn 42;   \n}\n}\n",
			expected =
				"function main():Int {\n  var text = \"{ literal }\"; // }\n  /* keep { } */\n  if (true) {\n    return 42;\n  }\n}\n",
			formatted = Formatter.format(source, FormatConfigTools.make(2, true));
		if (formatted != expected || Formatter.format(formatted, FormatConfigTools.make(2, true)) != expected)
			throw "canonical formatter output was not stable";

		var file = new SourceFile("round-trip.hx",
			"function main():String { var values:Array<Int> = [1,2]; var pattern=~/a[//]b/gi; var text='value ${1 + 2}'; // comment\nreturn text; }\n"),
			scanner = new FormatScanner(file),
			tokens = scanner.scan();
		if (scanner.roundTrip(tokens) != file.text)
			throw "lossless formatter scanner did not round-trip source bytes";
		var lexical = new Lexer(file).tokenize(),
			syntaxCount = 0,
			lexicalIndex = 0;
		for (token in tokens)
			switch token.kind {
				case FormatTokenKind.Syntax(kind):
					while (lexical[lexicalIndex].kind == TokenKind.Eof)
						break;
					if (lexical[lexicalIndex].kind != kind || lexical[lexicalIndex].text != token.text)
						throw "lossless scanner changed syntax token spelling";
					syntaxCount++;
					lexicalIndex++;
				default:
			}
		if (syntaxCount == 0 || lexical[lexicalIndex].kind != TokenKind.Eof)
			throw "lossless scanner changed syntax token sequence";
		var formattedRoundTrip = Formatter.format(file.text, FormatConfigTools.make(2, true)),
			reformattedLexical = new Lexer(new SourceFile("formatted.hx", formattedRoundTrip)).tokenize(),
			originalLexical = new Lexer(file).tokenize();
		lexicalIndex = 0;
		for (token in originalLexical) {
			if (token.kind == TokenKind.Eof)
				break;
			if (reformattedLexical[lexicalIndex].kind != token.kind
				|| reformattedLexical[lexicalIndex].text != token.text)
				throw "formatting changed the syntax token sequence";
			lexicalIndex++;
		}
		if (reformattedLexical[lexicalIndex].kind != TokenKind.Eof)
			throw "formatted source contained unexpected syntax tokens";

		var numericSource =
			"function main():Int { var values = [1e-12, 2E+10, 3e4, 1.25E-6, 1_000.5_0e-1_2, 0xCA_FE]; var nested:Array<Array<Int>> = []; var x = (64>>2) + (1<<2); x>>=1; x>>>=1; x<<=2; return x>>>1; }\n";
		for (width in [100, 20, 8]) {
			var numericConfig = FormatConfigTools.make(2, true);
			numericConfig.lineWidth = width;
			var output = Formatter.format(numericSource, numericConfig);
			for (literal in [
				"1e-12",
				"2E+10",
				"3e4",
				"1.25E-6",
				"1_000.5_0e-1_2",
				"0xCA_FE",
				">>",
				">>=",
				">>>=",
				"<<=",
				">>>",
				"<<"
			])
				if (output.indexOf(literal) < 0)
					throw "formatter split literal or operator " + literal + ": " + output;
			if (Formatter.format(output, numericConfig) != output)
				throw "numeric/shift formatting was not stable";
			var original = new Lexer(new SourceFile("before.hx", numericSource)).tokenize();
			var after = new Lexer(new SourceFile("after.hx", output)).tokenize();
			if (original.length != after.length)
				throw "numeric formatting changed token count";
			var scanned = new FormatScanner(new SourceFile("numeric.hx", numericSource)).scan();
			var syntaxTokens = [for (token in scanned)
				if (switch token.kind {
					case Syntax(_):
						true;
					default:
						false;
				}) token];
			if (syntaxTokens.length != original.length - 1)
				throw "numeric scanner changed token count";
			for (index in 0...syntaxTokens.length)
				if (compiler.formatter.FormatToken.FormatTokenTools.syntaxKind(syntaxTokens[index])
					!= original[index].kind
					|| syntaxTokens[index].text != original[index].text)
					throw "numeric scanner differs from compiler lexer";
			for (index in 0...original.length - 1)
				if (((original[index].kind == TokenKind.Greater
					&& (original[index + 1].kind == TokenKind.Greater
					|| original[index + 1].kind == TokenKind.GreaterEqual))
					|| (original[index].kind == TokenKind.Less
					&& (original[index + 1].kind == TokenKind.Less || original[index + 1].kind == TokenKind.LessEqual)))
					&& original[index].span.end == original[index + 1].span.start
					&& after[index].span.end != after[index + 1].span.start)
					throw "formatting broke operator adjacency";
			for (index in 0...original.length)
				if (original[index].kind != after[index].kind || original[index].text != after[index].text)
					throw "numeric formatting changed token spelling";
		}

		var config = FormatConfigTools.make(2, true);
		config.lineWidth = 60;
		var wrappedSource =
			"function build(name:String,arguments:Array<String>,configuration:Configuration):BuildResult { return computeSomething(firstValue,transform(secondValue),thirdValue); }\n",
			wrapped = Formatter.format(wrappedSource, config),
		// An over-long list is filled, wrapping as late as it fits: calls continue one level deeper, parameters two.
		expectedWrapped =
			"function build(name:String, arguments:Array<String>,\n    configuration:Configuration):BuildResult {\n  return computeSomething(firstValue,\n    transform(secondValue), thirdValue);\n}\n";
		if (wrapped != expectedWrapped || Formatter.format(wrapped, config) != expectedWrapped)
			throw "width-aware formatter did not choose a stable filled layout";
		for (line in wrapped.split("\n"))
			if (line.length > config.lineWidth)
				throw "breakable formatted output exceeded the configured line width";
		var wideContinuation = FormatConfigTools.make(2, true);
		wideContinuation.lineWidth = 40;
		wideContinuation.continuationIndentWidth = 4;
		var wideContinuationOutput =
			Formatter.format("function main():Int { return compute(firstValue,secondValue,thirdValue); }\n",
			wideContinuation);
		if (wideContinuationOutput
			!= "function main():Int {\n  return compute(firstValue,\n      secondValue, thirdValue);\n}\n")
			throw "continuation indentation width was not applied independently";
		var tabbed = Formatter.format("function main():Int { return 0; }\n", FormatConfigTools.make(2, false));
		if (tabbed == null || tabbed.indexOf("\n\treturn 0;") < 0)
			throw "tab indentation configuration was not honored";
		var genericConfig = FormatConfigTools.make(2, true);
		genericConfig.lineWidth = 40;
		var generic =
			Formatter.format("function main():Int { var value:Map<FirstArgument,SecondArgument> = []; return 0; }\n",
			genericConfig),
		// A type is read whole: the line breaks outside `Map<...>`, even when the type alone is wider than the line.
		expectedGeneric =
			"function main():Int {\n  var value:Map<FirstArgument, SecondArgument>\n    = [];\n  return 0;\n}\n";
		if (generic != expectedGeneric)
			throw "a type argument list was broken";

		var switchSource =
			"function main():Int { switch value { case First: return firstValue; case Second: return secondValue; default: return 0; } return 0; }\n",
			switchFormatted = Formatter.format(switchSource, config),
		// Arms written on their case's line stay there.
		expectedSwitch =
			"function main():Int {\n  switch value {\n    case First: return firstValue;\n    case Second: return secondValue;\n    default: return 0;\n  }\n  return 0;\n}\n";
		if (switchFormatted != expectedSwitch || Formatter.format(switchFormatted, config) != expectedSwitch)
			throw "switch cases did not receive stable structural indentation";
		var emptySwitch = Formatter.format("function main():Int { switch value {} return 0; }\n", config),
			expectedEmptySwitch = "function main():Int {\n  switch value {}\n  return 0;\n}\n";
		if (emptySwitch != expectedEmptySwitch)
			throw "an empty switch block did not stay {}";

		var expressionSource =
			"function main():Int { var result=firstCondition?firstValue:secondValue; return firstObject.secondObject.thirdObject.compute(firstArgument,secondArgument); }\n",
			expressionConfig = FormatConfigTools.make(2, true),
			expectedExpression =
				"function main():Int {\n  var result = firstCondition\n    ? firstValue : secondValue;\n  return firstObject.secondObject.thirdObject\n    .compute(firstArgument, secondArgument);\n}\n";
		expressionConfig.lineWidth = 50;
		var expressionFormatted = Formatter.format(expressionSource, expressionConfig);
		if (expressionFormatted != expectedExpression
			|| Formatter.format(expressionFormatted, expressionConfig) != expectedExpression)
			throw "expression chains and ternaries were not formatted canonically";

		var literalSource =
			"function main():Int { var values=[firstValue,secondValue,thirdValue,fourthValue]; var value={firstValue:firstValue,secondValue:secondValue,thirdValue:thirdValue}; return values[0]; }\n",
			literalFormatted = Formatter.format(literalSource, expressionConfig),
			expectedLiterals =
				"function main():Int {\n  var values = [\n    firstValue,\n    secondValue,\n    thirdValue,\n    fourthValue\n  ];\n  var value = {\n    firstValue: firstValue,\n    secondValue: secondValue,\n    thirdValue: thirdValue\n  };\n  return values[0];\n}\n";
		if (literalFormatted != expectedLiterals
			|| Formatter.format(literalFormatted, expressionConfig) != expectedLiterals)
			throw "array and object literal groups were not stable";

		var rangeSource = "function main():Int {\nvar first=1;\nvar second=2;\nreturn first+second;\n}\n",
			rangeStart = rangeSource.indexOf("first"),
			rangeEnd = rangeSource.indexOf("second") + "second=2;".length,
			rangeFormatted = Formatter.format(rangeSource, FormatConfigTools.make(2, true), rangeStart, rangeEnd);
		if (rangeFormatted == null
			|| rangeFormatted.indexOf("\n  var first = 1;\n  var second = 2;\nreturn first+second;") < 0)
			throw "range formatting did not expand to complete logical lines";
		var rangeConfig = FormatConfigTools.make(2, true);
		rangeConfig.lineWidth = 40;
		var callRangeSource =
			"function main():Int {\nvar result=compute(firstArgument,secondArgument,thirdArgument);\nreturn result;\n}\n",
			callRangeStart = callRangeSource.indexOf("secondArgument"),
			callRangeEnd = callRangeStart + "secondArgument".length,
			callRangeFormatted = Formatter.format(callRangeSource, rangeConfig, callRangeStart, callRangeEnd),
			expectedCallRange =
				"function main():Int {\n  var result = compute(firstArgument,\n    secondArgument, thirdArgument);\nreturn result;\n}\n";
		if (callRangeFormatted != expectedCallRange)
			throw "range formatting did not expand a partial call to its safe logical unit";

		var conditional =
			Formatter.format("#if missing\nfunction first():Int {\nreturn 1;\n}\n#else\nfunction second():Int {\nreturn 2;\n}\n#end\n",
			FormatConfigTools.make(2, true)),
			expectedConditional =
				"#if missing\nfunction first():Int {\n  return 1;\n}\n#else\nfunction second():Int {\n  return 2;\n}\n#end\n";
		if (conditional != expectedConditional)
			throw "conditional branches disturbed formatter indentation";

		for (inlineConditionalSource in [
			"function main():Int { var value = #if feature 41 #else 42 #end; return value; }\n",
			"function main():Int { var value = #if (feature || other)\n41;\n#else\n42;\n#end\nreturn value; }\n",
			"function main():Int return identity(#if feature 40 #elseif other 41 #else 42 #end);\n"
		]) {
			var inlineConditional = Formatter.format(inlineConditionalSource, FormatConfigTools.make(2, true));
			if (inlineConditional == null
				|| Formatter.format(inlineConditional, FormatConfigTools.make(2, true)) != inlineConditional)
				throw "inline conditional formatting did not preserve valid, stable source";
			for (defines in [new Map<String, String>(), ["feature" => "1"], ["other" => "1"]]) {
				var beforeFile = new SourceFile("inline-before.hx", inlineConditionalSource),
					afterFile = new SourceFile("inline-after.hx", inlineConditional),
					beforeActive = compiler.syntax.ConditionalCompilation.process(beforeFile, defines),
					afterActive = compiler.syntax.ConditionalCompilation.process(afterFile, defines),
					beforeTokens = new Lexer(beforeFile, beforeActive.text).tokenize(),
					afterTokens = new Lexer(afterFile, afterActive.text).tokenize();
				if (beforeTokens.length != afterTokens.length)
					throw "inline conditional formatting changed active token count";
				for (index in 0...beforeTokens.length)
					if (beforeTokens[index].kind != afterTokens[index].kind
						|| beforeTokens[index].text != afterTokens[index].text)
						throw "inline conditional formatting changed an active branch";
			}
		}

		var disabledSource =
			"function main():Int { // @formatter:off\n   var   untouched=foo( 1,2 );\n // @formatter:on\nreturn 0; }\n",
			disabled = Formatter.format(disabledSource, FormatConfigTools.make(2, true)),
			expectedDisabled =
				"function main():Int { // @formatter:off\n   var   untouched=foo( 1,2 );\n // @formatter:on\n  return 0;\n}\n";
		if (disabled != expectedDisabled)
			throw "formatter-off region was not preserved verbatim";
		var markerInString =
			Formatter.format("function main():String {\nvar text=\"@formatter:off\";\nreturn text;\n}\n",
			FormatConfigTools.make(2, true)),
			expectedMarkerInString = "function main():String {\n  var text = \"@formatter:off\";\n  return text;\n}\n";
		if (markerInString != expectedMarkerInString)
			throw "formatter markers inside strings changed formatting state";

		var crlf = Formatter.format(StringTools.replace(source, "\n", "\r\n"), FormatConfigTools.make(2, true));
		if (crlf == null || crlf.indexOf("\r\n") < 0 || crlf.indexOf("\n") != crlf.indexOf("\r\n") + 1)
			throw "formatter did not preserve CRLF output";
		if (Formatter.format("function main(:Int {", FormatConfigTools.make(2, true)) != null)
			throw "formatter accepted malformed source";
		var structSource = "struct Vec2 {\npublic var x:Int;\n}\n",
			structFormatted = Formatter.format(structSource, FormatConfigTools.make(2, true));
		if (structFormatted == null
			|| structFormatted.indexOf("struct Vec2") < 0
			|| Formatter.format(structFormatted, FormatConfigTools.make(2, true)) != structFormatted)
			throw "formatter did not preserve struct declaration syntax";

		Sys.println("PASS: lossless width-aware formatter");
	}
}
