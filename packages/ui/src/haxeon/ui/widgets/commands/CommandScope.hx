package haxeon.ui.widgets.commands;
import haxeon.ui.core.ViewRoot;

import haxeon.ui.core.BuildContext;
import haxeon.ui.core.RootModifier;
import haxeon.ui.core.View;

/**
 * Contributes a command scope to the focused subtree without changing the
 * registry's global scope stack. Focused descendants automatically receive
 * this scope's shortcut precedence during keyboard routing.
 */
class CommandScope implements View {
	/** The scope whose shortcuts take precedence while focus is inside `child`. */
	public final scope:String;
	final child:View;

	/** Shows `child`, with `scope`'s shortcuts first while focus is inside it. */
	public function new(scope:String, child:View) {
		if (scope == null || scope.length == 0 || child == null)
			throw "Command scopes require a stable name and child view";
		this.scope = scope;
		this.child = child;
	}

	public function build(context:BuildContext):ViewRoot {
		var modifier = new RootModifier();
		modifier.commandScope = scope;
		return context.build(child, modifier);
	}
}
