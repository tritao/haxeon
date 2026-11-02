package haxeon.ui.core;

import Observable;

/** Observable holder for the immutable invocation context active in a build frame. */
class CommandContextState implements Observable {
	public var value:CommandContext;

	public function new()
		value = new CommandContext();
}
