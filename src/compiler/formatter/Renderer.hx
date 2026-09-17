package compiler.formatter;

import compiler.formatter.LayoutSolver.LineLayout;
import compiler.formatter.FormatConfig.FormatConfigTools;
import compiler.formatter.FormatToken.FormatTokenKind;

/** Renders a solved logical line without consulting the original whitespace. */
class Renderer {
	public static function render(line:UnwrappedLine, layout:LineLayout, boundaries:Array<Boundary>, config:FormatConfig):Array<String> {
		var result:Array<String> = [];
		for (physical in layout.lines) {
			var output = new StringBuf();
			var verbatim = line.tokens.length == 1 && line.tokens[0].kind == FormatTokenKind.FormatterOff;
			if (!verbatim)
				output.add(FormatConfigTools.indentation(physical.indent, config));
			for (index in physical.start...physical.end + 1) {
				if (index > physical.start)
					addSpaces(output, boundaries[index - 1].spaces);
				output.add(line.tokens[index].text);
			}
			result.push(output.toString());
		}
		return result;
	}

	static function addSpaces(output:StringBuf, count:Int):Void
		for (_ in 0...count)
			output.add(" ");
}
