package compiler.types.typing;

import compiler.core.Diagnostic;
import compiler.core.Diagnostic.CompileError;
import compiler.core.Source.SourceSpan;
import compiler.syntax.Ast.AstExpression;
import compiler.syntax.Ast.AstStatement;

/** A switch whose structure patterns were rewritten: `subject` is the tuple of the fields they read, `values` the cases' patterns. */
typedef StructureSwitch = {
	/** The declaration of the variable that holds the subject, when the subject is not one already. */
	final temporary:Null<AstStatement>;

	final subject:AstExpression;
	final values:Array<AstExpression>;
}

/**
 * Haxe's structure patterns, `case {x: 1, y: y}:`, as the tuple switch Haxe's matcher makes of them: each field a case names is
 * a column, read from the subject (`[subject.x, subject.y]`), and each case the tuple pattern of its fields, `_` for a field it
 * leaves out. A nested structure pattern adds the columns of its fields (`{a: {b: 1}}` reads `subject.a.b`); a capture of the
 * whole subject or of a field (`case p = {x: 0}:`, `case {a: inner = {b: 1}}:`) is a column of its own, which it binds. The
 * tuple switch then gives each field pattern its own type and the exhaustiveness rules of a tuple (`TupleSwitch`): a field of an
 * enum type is covered constructor by constructor, an Int field only by `_`.
 */
class StructurePatterns {
	/** Whether a case of the switch is a structure pattern: an object literal, whole or captured. */
	public static function present(values:Array<AstExpression>):Bool {
		for (value in values)
			if (isStructure(value))
				return true;
		return false;
	}

	static function isStructure(value:AstExpression):Bool
		return switch value {
			case ObjectLiteral(_, _): true;
			case Capture(_, inner, _): isStructure(inner);
			default: false;
		};

	/** The tuple switch of a switch over `subject` with the case patterns `values`, some of them structure patterns. */
	public static function rewrite(subject:AstExpression, values:Array<AstExpression>,
			span:SourceSpan):StructureSwitch {
		var columns:Array<String> = [],
			rows:Array<Map<String, AstExpression>> = [],
			fieldSpans:Map<String, SourceSpan> = [];
		for (value in values) {
			var row:Map<String, AstExpression> = [];
			collect(value, "", row, columns, true, fieldSpans);
			rows.push(row);
		}
		var temporary:Null<AstStatement> = null,
			holder = subject;
		switch subject {
			case Variable(name, _) if (name != "this"):
			default:
				var name = "__haxeon_structure" + span.start;
				temporary = VarDeclaration(name, null, subject, span);
				holder = Variable(name, span);
		}
		// Cases that name no field still match through a tuple: one of the subject itself.
		if (columns.length == 0)
			columns.push("");
		var elements = [for (column in columns) read(holder, column, fieldSpans, span)];
		return {
			temporary: temporary,
			subject: ArrayLiteral(elements, span),
			values: [
				for (index in 0...values.length)
					ArrayLiteral([
						for (column in columns)
							rows[index].exists(column) ? rows[index].get(column) : Variable("_",
							patternSpan(values[index]))
					], patternSpan(values[index]))
			]
		};
	}

	/**
	 * The column patterns of `pattern`, matched at the field path `path` ("" for the subject, "a.b" for `subject.a.b`). At the
	 * subject itself only a structure, `_` or a capture can stand: the subject is matched field by field.
	 */
	static function collect(pattern:AstExpression, path:String, row:Map<String, AstExpression>, columns:Array<String>,
			root:Bool, fieldSpans:Map<String, SourceSpan>):Void {
		switch pattern {
			case ObjectLiteral(fields, _):
				for (field in fields) {
					var fieldPath = path == "" ? field.name : path + "." + field.name;
					if (row.exists(fieldPath))
						throw new CompileError(new Diagnostic("E1019",
							'Duplicate field "${field.name}" in structure pattern',
							field.span));
					if (!fieldSpans.exists(fieldPath))
						fieldSpans.set(fieldPath, field.span);
					collect(field.value, fieldPath, row, columns, false, fieldSpans);
				}
			case Capture(name, inner, span) if (isStructure(inner)):
				set(path, Variable(name, span), row, columns);
				collect(inner, path, row, columns, root, fieldSpans);
			case Variable("_", _):
			case Variable(_, _):
				set(path, pattern, row, columns);
			default:
				if (root)
					throw new CompileError(new Diagnostic("E1019",
						"A switch with structure patterns matches structures, captures or _ in each case",
						patternSpan(pattern)));
				set(path, pattern, row, columns);
		}
	}

	static function set(path:String, pattern:AstExpression, row:Map<String, AstExpression>,
			columns:Array<String>):Void {
		row.set(path, pattern);
		if (columns.indexOf(path) < 0)
			columns.push(path);
	}

	/** The read of the field at `path`, at the pattern's field for an error there (`{missing: 1}` names no field). */
	static function read(holder:AstExpression, path:String, fieldSpans:Map<String, SourceSpan>,
			span:SourceSpan):AstExpression {
		var value = holder, prefix = "";
		if (path != "")
			for (name in path.split(".")) {
				prefix = prefix == "" ? name : prefix + "." + name;
				var fieldSpan = fieldSpans.get(prefix);
				value = Member(value, name, fieldSpan == null ? span : fieldSpan);
			}
		return value;
	}

	static function patternSpan(pattern:AstExpression):SourceSpan
		return compiler.syntax.Parser.expressionSpan(pattern);
}
