package haxeon.platform.internal;

import haxeon.platform.BindingError;
import haxeon.platform.DisposalRegistration;

/** Removable ownership registrations; successful releases never retain wrappers. */
class DisposalRegistry {
	final entries:Array<DisposalRegistration> = [];

	public function new() {}

	public function register(release:Void->Void):DisposalRegistration {
		if (release == null) throw BindingError.invalidArgument("DisposalRegistry.register", "Release callback cannot be null");
		var entry = new DisposalRegistration(this, release);
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

	@:allow(DisposalRegistration)
	function remove(entry:DisposalRegistration):Void { entries.remove(entry); }
}
