import compiler.core.Source.SourceFile;
import compiler.syntax.Lexer;
import compiler.syntax.Parser;
import compiler.types.SignatureInference;

/** Inference must not erase annotations or modifiers from a callable declaration. */
class SignatureMetadataMain {
	static function main():Void {
		var source = new SourceFile('Main.hx',
			'@:keep inline function top(value = 1) return value; '
			+ 'class Subject { @:access(Subject) public static inline function method(value:Int) return value; }');
		var parsed = new Parser(new Lexer(source).tokenize()).parseProgram(),
			inferred = SignatureInference.inferProgram(parsed);
		var top = inferred.functions[0],
			method = inferred.classes[0].methods[0];
		if (top.metadata == null || top.metadata.length != 1 || top.metadata[0].name != 'keep' || top.isInline != true)
			throw 'Argument inference erased the top-level annotation or inline modifier';
		if (method.metadata == null || method.metadata.length != 1 || method.metadata[0].name != 'access'
			|| method.isInline != true)
			throw 'Return inference erased the method annotation or inline modifier';
		switch top.arguments[0].type {
			case IntType:
			default:
				throw 'Default argument type was not inferred';
		}
		switch method.result {
			case IntType:
			default:
				throw 'Return type was not inferred';
		}
		Sys.println('PASS: signature inference preserves callable annotations');
	}
}
