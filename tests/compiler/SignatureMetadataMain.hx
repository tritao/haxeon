import compiler.core.Source.SourceFile;
import compiler.syntax.Lexer;
import compiler.syntax.Parser;
import compiler.types.AccessorSignatures;

/** Giving an unannotated accessor its property's type must not erase annotations or modifiers from it. */
class SignatureMetadataMain {
	static function main():Void {
		var source = new SourceFile('Main.hx', 'class Subject { public var value(get, set):Int; '
			+ '@:keep inline function get_value() return 1; '
			+ '@:access(Subject) inline function set_value(next) return next; }');
		var parsed = new Parser(new Lexer(source).tokenize()).parseProgram(),
			typed = AccessorSignatures.withPropertyTypes(parsed);
		var getter = typed.classes[0].methods[0],
			setter = typed.classes[0].methods[1];
		if (getter.metadata == null || getter.metadata.length != 1 || getter.metadata[0].name != 'keep'
			|| getter.isInline != true)
			throw 'The getter lost its annotation or inline modifier';
		if (setter.metadata == null || setter.metadata.length != 1 || setter.metadata[0].name != 'access'
			|| setter.isInline != true)
			throw 'The setter lost its annotation or inline modifier';
		switch getter.result {
			case IntType:
			default:
				throw 'The getter does not return the property type';
		}
		switch [setter.arguments[0].type, setter.result] {
			case [IntType, IntType]:
			default:
				throw 'The setter does not take and return the property type';
		}
		Sys.println('PASS: an accessor given its property type keeps its annotations');
	}
}
