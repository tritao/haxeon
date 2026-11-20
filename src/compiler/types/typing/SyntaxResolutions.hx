package compiler.types.typing;

import compiler.core.InternalError;
import compiler.syntax.Ast.AstArgument;
import compiler.syntax.Ast.AstField;
import compiler.types.analysis.BodyResolution;
import haxe.ds.ObjectMap;

/**
 * The resolutions of the expressions a declaration holds outside a body: a field's or an inline constant's initializer,
 * and an argument's default value, which is typed at every call that omits it. Each is made once, the first time it is
 * typed, and kept with its declaration's syntax (docs/design/BODY_RESOLUTION.md).
 */
class SyntaxResolutions {
	final initializers = new ObjectMap<AstField, BodyResolution>();
	final defaults = new ObjectMap<AstArgument, BodyResolution>();

	public function new() {}

	/** The resolution of `field`'s initializer. */
	public function ofInitializer(field:AstField):BodyResolution {
		var found = initializers.get(field);
		if (found == null) {
			var initializer = field.initializer;
			if (initializer == null)
				throw new InternalError('Field "${field.name}" has no initializer to resolve');
			found = BodyResolution.ofExpression(initializer);
			initializers.set(field, found);
		}
		return found;
	}

	/** The resolution of `argument`'s default value. */
	public function ofDefault(argument:AstArgument):BodyResolution {
		var found = defaults.get(argument);
		if (found == null) {
			var value = argument.defaultValue;
			if (value == null)
				throw new InternalError('Argument "${argument.name}" has no default value to resolve');
			// The cache lives as long as the syntax it is keyed by: what it holds is made outside the arena of the work asking.
			found = compiler.core.Arena.within(compiler.core.Arena.global, () -> BodyResolution.ofExpression(value));
			defaults.set(argument, found);
		}
		return found;
	}
}
