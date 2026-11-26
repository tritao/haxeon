package compiler.documentation;

import compiler.core.Diagnostic;
import compiler.core.DiagnosticCode;
import compiler.documentation.ApiModel.ApiMember;
import compiler.documentation.ApiModel.ApiSource;

/**
 * Whether every declaration of a package's API says what it is for: what `--require-docs` (a package's
 * `package.documentation = "required"`) checks. The API is what the model describes, without what is `internal`: each type, each
 * of its members, and each module's own functions and variables. A member documents itself, or inherits the comment of the
 * member it overrides or implements (`ApiMember.inherited`).
 */
class DocumentationCoverage {
	/** An error for each declaration of `model`'s API that has no doc comment, in the model's order. */
	public static function missing(model:ApiModel):Array<Diagnostic> {
		var described = [for (path in model.described) path => true], result:Array<Diagnostic> = [];
		for (type in model.types) {
			if (!described.exists(type.module) || !isApi(type.source))
				continue;
			var name = type.path.substr(type.path.lastIndexOf(".") + 1);
			if (type.source.documentation == null)
				result.push(error(type.source, '${type.kind} "$name"'));
			for (member in type.members)
				if (isApi(member.source) && !documented(member))
					result.push(error(member.source, '${memberKind(member)} "$name.${member.name}"'));
		}
		for (module in model.modules)
			if (described.exists(module.path))
				for (member in module.members)
					if (isApi(member.source) && member.source.documentation == null)
						result.push(error(member.source, '${memberKind(member)} "${module.path}.${member.name}"'));
		return result;
	}

	static function isApi(source:ApiSource):Bool
		return source.visibility != "internal";

	static function documented(member:ApiMember):Bool
		return member.source.documentation != null || member.inherited != null;

	static function memberKind(member:ApiMember):String
		return switch member.kind {
			case "enumConstructor", "enumValue": "case";
			case "conversion": "conversion";
			case "operator": "operator";
			case "function": "function";
			case kind: kind;
		};

	static function error(source:ApiSource, what:String):Diagnostic
		return new Diagnostic(DiagnosticCode.MISSING_DOCUMENTATION,
			'Public $what has no doc comment; document it, or make it internal if it is not for other packages',
			source.span);
}
