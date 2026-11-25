package haxeon.platform;

import haxeon.platform.BindingError;
import haxeon.platform.DisposalRegistration;

/**
 * The cleanups of what one owner (a renderer, a window) has created: each is registered when its resource is made and run
 * when the owner releases everything, latest first. A registration that releases or detaches early leaves the registry, so
 * released resources are not kept alive.
 */
class DisposalRegistry {
	final entries:Array<DisposalRegistration> = [];

	/** An empty registry. */
	public function new() {}

	/**
	 * Registers `release` to run when the registry releases its entries. The registration it returns detaches it, for a
	 * resource disposed of on its own. Throws when `release` is null.
	 */
	public function register(release:Void->Void):DisposalRegistration {
		if (release == null) throw BindingError.invalidArgument("DisposalRegistry.register",
			"Release callback cannot be null");
		var entry = new DisposalRegistration(this, release);
		entries.push(entry);
		return entry;
	}

	/** Runs every registered release, latest first; one that throws stays registered, and the first error is rethrown. */
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

	/** How many registrations are still held. */
	public function count():Int return entries.length;

	@:allow(haxeon.platform.DisposalRegistration)
	function remove(entry:DisposalRegistration):Void {
		entries.remove(entry);
	}
}
