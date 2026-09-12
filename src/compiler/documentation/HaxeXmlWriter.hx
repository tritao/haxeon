package compiler.documentation;

import compiler.modules.ModuleState;
import compiler.syntax.Ast;
import compiler.syntax.Ast.AstArgument;
import compiler.syntax.Ast.AstFunction;
import compiler.syntax.Ast.AstType;
import compiler.documentation.Documentation.DocumentationComment;
import compiler.documentation.Documentation.DocumentationTools;

/** Emits the Haxe type-description XML consumed by documentation tools such as dox. */
class HaxeXmlWriter {
	public static function emit(modules:Map<String, ModuleState>):String {
		var names = [for (name in modules.keys()) name];
		names.sort(Reflect.compare);
		var output = new StringBuf();
		output.add('<?xml version="1.0" encoding="utf-8"?>\n<haxe>\n');
		for (name in names) {
			var state = modules.get(name);
			if (state == null)
				continue;
			var program = state.ast;
			if (program != null)
				emitModule(output, state, program);
		}
		output.add('</haxe>\n');
		return output.toString();
	}

	static function emitModule(output:StringBuf, state:ModuleState, program:AstProgram):Void {
		var comments = DocumentationTools.scan(state.source);
		for (alias in program.aliases) {
			openType(output, "typedef", qualified(program, alias.name), alias.typeParameters, state, alias.span, alias.isPrivate);
			emitType(output, alias.type);
			emitDocumentation(output, state, comments, alias.span);
			output.add('</typedef>\n');
		}
		for (decl in program.enums) {
			openType(output, "enum", qualified(program, decl.name), decl.typeParameters, state, decl.span, false);
			emitDocumentation(output, state, comments, decl.span);
			for (enumCase in decl.cases) {
				output.add('<');
				output.add(escape(enumCase.name));
				output.add(' public="1">');
				if (enumCase.params.length > 0) {
					output.add('<f a="');
					output.add(escape([for (parameter in enumCase.params) parameter.name == null ? "" : parameter.name].join(":")));
					output.add('">');
					for (parameter in enumCase.params)
						emitType(output, parameter.type);
					emitNamed(output, qualified(program, decl.name));
					output.add('</f>');
				} else
					emitNamed(output, qualified(program, decl.name));
				emitDocumentation(output, state, comments, enumCase.span);
				output.add('</');
				output.add(escape(enumCase.name));
				output.add('>\n');
			}
			output.add('</enum>\n');
		}
		for (decl in program.interfaces) {
			openType(output, "class", qualified(program, decl.name), decl.typeParameters, state, decl.span, false, ' interface="1"');
			for (base in decl.bases) {
				output.add('<implements>');
				emitType(output, base);
				output.add('</implements>');
			}
			emitDocumentation(output, state, comments, decl.span);
			for (method in decl.methods)
				emitFunction(output, state, comments, method);
			output.add('</class>\n');
		}
		for (decl in program.classes) {
			openType(output, "class", qualified(program, decl.name), decl.typeParameters, state, decl.span, decl.isPrivate,
				decl.isExtern == true ? ' extern="1"' : "");
			if (decl.base != null) {
				output.add('<extends>');
				emitType(output, decl.base);
				output.add('</extends>');
			}
			for (implemented in decl.interfaces) {
				output.add('<implements>');
				emitType(output, implemented);
				output.add('</implements>');
			}
			emitDocumentation(output, state, comments, decl.span);
			for (field in decl.fields) {
				output.add('<');
				output.add(escape(field.name));
				output.add(' public="1"');
				if (field.isStatic)
					output.add(' static="1"');
				if (field.isFinal)
					output.add(' final="1"');
				output.add('>');
				emitType(output, field.type == null ? InferredType : field.type);
				emitDocumentation(output, state, comments, field.span);
				output.add('</');
				output.add(escape(field.name));
				output.add('>\n');
			}
			for (method in decl.methods)
				emitFunction(output, state, comments, method);
			output.add('</class>\n');
		}
		for (decl in program.abstracts) {
			openType(output, "abstract", qualified(program, decl.name), decl.typeParameters, state, decl.span, false,
				decl.isExtern == true ? ' extern="1"' : "");
			output.add('<this>');
			emitType(output, decl.underlying);
			output.add('</this>');
			emitDocumentation(output, state, comments, decl.span);
			for (method in decl.methods)
				emitFunction(output, state, comments, method);
			output.add('</abstract>\n');
		}
		for (decl in program.enumAbstracts) {
			openType(output, "abstract", qualified(program, decl.name), [], state, decl.span, false);
			output.add('<this>');
			emitType(output, decl.underlying);
			output.add('</this>');
			emitDocumentation(output, state, comments, decl.span);
			for (value in decl.values) {
				output.add('<');
				output.add(escape(value.name));
				output.add(' public="1" static="1">');
				emitType(output, decl.underlying);
				emitDocumentation(output, state, comments, value.span);
				output.add('</');
				output.add(escape(value.name));
				output.add('>\n');
			}
			output.add('</abstract>\n');
		}
		if (program.functions.length > 0) {
			openType(output, "class", state.name
				+ ".Module", [], state, program.functions[0].span, true, ' module="'
				+ escape(state.name)
				+ '"');
			for (fn in program.functions)
				emitFunction(output, state, comments, fn);
			output.add('</class>\n');
		}
	}

	static function openType(output:StringBuf, tag:String, path:String, parameters:Array<String>, state:ModuleState, span:compiler.Source.SourceSpan,
			isPrivate:Bool, extra:String = ""):Void {
		output.add('<');
		output.add(tag);
		output.add(' path="');
		output.add(escape(path));
		output.add('" params="');
		output.add(escape(parameters.join(":")));
		output.add('" file="');
		output.add(escape(state.source.path));
		output.add('"');
		if (isPrivate)
			output.add(' private="1"');
		output.add(extra);
		output.add('>');
	}

	static function emitFunction(output:StringBuf, state:ModuleState, comments:Array<DocumentationComment>, fn:AstFunction):Void {
		output.add('<');
		output.add(escape(fn.name));
		output.add(' public="1" set="method"');
		if (fn.isStatic)
			output.add(' static="1"');
		output.add('><f a="');
		output.add(escape([for (argument in fn.arguments) argument.name].join(":")));
		output.add('">');
		for (argument in fn.arguments)
			emitType(output, argument.optional == true ? NullableType(argument.type) : argument.type);
		emitType(output, fn.result);
		output.add('</f>');
		emitDocumentation(output, state, comments, fn.span);
		output.add('</');
		output.add(escape(fn.name));
		output.add('>\n');
	}

	static function emitDocumentation(output:StringBuf, state:ModuleState, comments:Array<DocumentationComment>, span:compiler.Source.SourceSpan):Void {
		var documentation = DocumentationTools.forSpan(state.source, comments, span);
		if (documentation.raw.length > 0) {
			output.add('<haxe_doc>');
			output.add(escape(documentation.raw));
			output.add('</haxe_doc>');
		}
	}

	static function emitType(output:StringBuf, type:AstType):Void {
		switch type {
			case IntType:
				emitNamed(output, "Int");
			case BoolType:
				emitNamed(output, "Bool");
			case FloatType:
				emitNamed(output, "Float");
			case StringType:
				emitNamed(output, "String");
			case VoidType:
				output.add('<e path="Void"/>');
			case InferredType | ErrorType(_):
				emitNamed(output, "Dynamic");
			case NativeAbstractType(name, _):
				emitNamed(output, name);
			case NamedType(name):
				emitNamed(output, name);
			case AppliedType(name, arguments):
				emitApplied(output, name, arguments);
			case ArrayType(element):
				emitApplied(output, "Array", [element]);
			case MapType(key, value):
				emitApplied(output, "Map", [key, value]);
			case NullableType(element):
				emitApplied(output, "Null", [element]);
			case FunctionType(arguments, result):
				output.add('<f a="">');
				for (argument in arguments)
					emitType(output, argument);
				emitType(output, result);
				output.add('</f>');
			case AnonymousType(fields):
				output.add('<a>');
				for (field in fields) {
					output.add('<');
					output.add(escape(field.name));
					output.add(field.optional ? ' optional="1">' : '>');
					emitType(output, field.type);
					output.add('</');
					output.add(escape(field.name));
					output.add('>');
				}
				output.add('</a>');
		}
	}

	static function emitApplied(output:StringBuf, name:String, arguments:Array<AstType>):Void {
		output.add('<c path="');
		output.add(escape(name));
		output.add('">');
		for (argument in arguments)
			emitType(output, argument);
		output.add('</c>');
	}

	static function emitNamed(output:StringBuf, name:String):Void {
		output.add('<c path="');
		output.add(escape(name));
		output.add('"/>');
	}

	static function qualified(program:AstProgram, name:String):String
		return program.packageName == null || program.packageName.length == 0 ? name : program.packageName + "." + name;

	static function escape(value:String):String
		return StringTools.replace(StringTools.replace(StringTools.replace(StringTools.replace(StringTools.replace(value, "&", "&amp;"), "<", "&lt;"), ">",
			"&gt;"), "\"", "&quot;"),
			"'", "&apos;");
}
