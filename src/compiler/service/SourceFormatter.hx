package compiler.service;

import compiler.formatter.FormatConfig.FormatConfigTools;
import compiler.formatter.Formatter;

/** Compatibility facade for the lossless, syntax-aware formatter engine. */
class SourceFormatter {
	public static function format(source:String, tabSize:Int, insertSpaces:Bool, ?rangeStart:Int, ?rangeEnd:Int):Null<String>
		return Formatter.format(source, FormatConfigTools.defaults(tabSize, insertSpaces), rangeStart, rangeEnd);
}
