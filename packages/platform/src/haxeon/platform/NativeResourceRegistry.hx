package haxeon.platform;

/** Removable ownership registrations; successful releases never retain wrappers. */
class NativeResourceRegistry {
	final entries:Array<NativeResourceRegistration> = [];

	public function new() {}

	public function register(release:Void->Void):NativeResourceRegistration {
		if (release == null) throw BindingError.invalidArgument("NativeResourceRegistry.register", "Release callback cannot be null");
		var entry = new NativeResourceRegistration(this, release);
		entries.push(entry);
		return entry;
	}

	/** Attempts every child in reverse creation order. Failed children remain retryable. */
	public function releaseAll():Void {
		var snapshot = entries.copy();
		var failure:Dynamic = null;
		for (index in 0...snapshot.length) {
			var entry = snapshot[snapshot.length - 1 - index];
			try entry.release() catch (error:Dynamic) {
				if (failure == null) failure = error;
			}
		}
		if (failure != null) throw failure;
	}

	public function count():Int return entries.length;

	@:allow(NativeResourceRegistration)
	function remove(entry:NativeResourceRegistration):Void { entries.remove(entry); }
}

/** Detach after manual disposal; release invokes the owner's cleanup first. */
class NativeResourceRegistration {
	var owner:Null<NativeResourceRegistry>;
	var action:Null<Void->Void>;

	@:allow(NativeResourceRegistry)
	private function new(owner:NativeResourceRegistry, action:Void->Void) {
		this.owner = owner;
		this.action = action;
	}

	public function detach():Void {
		if (owner != null) owner.remove(this);
		owner = null;
		action = null;
	}

	@:allow(NativeResourceRegistry)
	function release():Void {
		if (action == null) return;
		action();
		detach();
	}
}
