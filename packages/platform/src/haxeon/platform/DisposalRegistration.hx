package haxeon.platform;

import haxeon.platform.internal.DisposalRegistry;

/** Detach after manual disposal; release invokes the owner's cleanup first. */
class DisposalRegistration {
	var owner:Null<DisposalRegistry>;
	var action:Null<Void->Void>;

	@:allow(DisposalRegistry)
	private function new(owner:DisposalRegistry, action:Void->Void) {
		this.owner = owner;
		this.action = action;
	}

	public function detach():Void {
		if (owner != null) owner.remove(this);
		owner = null;
		action = null;
	}

	@:allow(DisposalRegistry)
	function release():Void {
		if (action == null) return;
		action();
		detach();
	}
}
