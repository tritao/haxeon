package haxeon.animation;

/**
 * Plays one clip at a time on an instance and crossfades between clips.
 * The outgoing clips keep advancing while their weights fade to zero. One overlay clip may be mixed over
 * all of that at a weight the caller sets, to hold a pose such as a crouch at any depth between the two.
 */
class ClipPlayer {
	public final instance:AnimationInstance;
	/** Playback rate multiplier applied to both clips. */
	public var speed:Float = 1.0;

	/** Layers the instance holds besides the current clip's and the overlay's. */
	static inline var MAX_OUTGOING:Int = AnimationInstance.MAX_LAYERS - 2;
	static inline var OVERLAY_LAYER:Int = AnimationInstance.MAX_LAYERS - 1;

	var clip:Int = -1;
	var time:Float = 0.0;
	var loop:Bool = true;
	/**
	 * Clips fading out, each with the share of the outgoing blend it holds (the shares sum to one).
	 * A clip started while another fade is still running keeps the earlier outgoing clips, so the
	 * pose continues from the blend it was in instead of snapping to the current clip alone.
	 */
	final outgoing:Array<{clip:Int, time:Float, loop:Bool, share:Float}> = [];
	var fadeDuration:Float = 0.0;
	var fadeElapsed:Float = 0.0;
	var overlayClip:Int = -1;
	var overlayTime:Float = 0.0;
	var overlayWeight:Float = 0.0;
	/** A time to hold the overlay at instead of letting it run, or null. */
	var overlayHold:Null<Float> = null;

	public function new(instance:AnimationInstance) {
		this.instance = instance;
	}

	public function currentClip():Int
		return clip;

	/** How far the current clip has faded in, 0 to 1; one when nothing is fading. */
	public function fadeWeight():Float
		return currentWeight();

	/** Whether a crossfade between clips is still running. */
	public function fading():Bool
		return outgoing.length > 0;

	public function currentTime():Float
		return time;

	/** Starts a clip by name; returns false when the asset has no such clip. */
	public function playNamed(name:String, fadeSeconds:Float = 0.2, loop:Bool = true):Bool {
		var index = instance.asset.clipIndex(name);
		if (index < 0)
			return false;
		play(index, fadeSeconds, loop);
		return true;
	}

	/** Starts a clip from its beginning, fading from the current one. Replaying the current clip is a no-op. */
	public function play(index:Int, fadeSeconds:Float = 0.2, loop:Bool = true, startSeconds:Float = 0.0):Void {
		if (index < 0 || index >= instance.asset.clipNames.length)
			throw 'Clip index $index is out of range';
		if (index == clip)
			return;
		if (clip >= 0 && fadeSeconds > 0.0) {
			// The blend now is the current clip at its fade weight over the outgoing ones at the rest.
			var incoming = currentWeight();
			for (entry in outgoing) entry.share *= 1.0 - incoming;
			outgoing.push({clip: clip, time: time, loop: this.loop, share: incoming});
			dropWeakest();
			fadeDuration = fadeSeconds;
			fadeElapsed = 0.0;
		} else {
			outgoing.resize(0);
		}
		clip = index;
		time = startSeconds;
		this.loop = loop;
	}

	/**
	 * Starts a clip from its beginning with no fade, even when it is already the
	 * current clip, dropping any crossfade in progress and returning the rate to
	 * normal. This puts the player back as if the clip had just been started.
	 */
	public function restart(index:Int, loop:Bool = true):Void {
		if (index < 0 || index >= instance.asset.clipNames.length)
			throw 'Clip index $index is out of range';
		outgoing.resize(0);
		fadeDuration = 0.0;
		fadeElapsed = 0.0;
		clip = index;
		time = 0.0;
		this.loop = loop;
		speed = 1.0;
	}

	/**
	 * Mixes a clip over everything else at `weight` (0 none, 1 only the overlay), looping on its own clock. A
	 * negative clip, or a weight of zero, takes it out of the mix; the clock keeps running, so putting the same
	 * clip back picks up where it would be rather than from its start. With `hold` the overlay does not run but
	 * stays at that time in the clip, which poses the body part way through a one-way clip. Takes effect from the
	 * next advance.
	 */
	public function setOverlay(index:Int, weight:Float, ?hold:Float):Void {
		if (index >= instance.asset.clipNames.length)
			throw 'Clip index $index is out of range';
		if (index >= 0 && index != overlayClip) {
			overlayClip = index;
			overlayTime = 0.0;
		}
		overlayWeight = index < 0 ? 0.0 : Math.max(0.0, Math.min(1.0, weight));
		overlayHold = hold;
	}

	public function overlayAmount():Float
		return overlayWeight;

	/** The current clip's weight: how far its fade-in has run, or one when nothing is fading out. */
	function currentWeight():Float
		return outgoing.length == 0 || fadeDuration <= 0.0 ? 1.0 : Math.min(1.0, fadeElapsed / fadeDuration);

	/** Keeps the instance's spare layers enough: the weakest outgoing clip goes, and the rest rescale. */
	function dropWeakest():Void {
		while (outgoing.length > MAX_OUTGOING) {
			var weakest = 0;
			for (index in 1...outgoing.length) if (outgoing[index].share < outgoing[weakest].share) weakest = index;
			outgoing.splice(weakest, 1);
			var total = 0.0;
			for (entry in outgoing) total += entry.share;
			if (total > 0.0) for (entry in outgoing) entry.share /= total;
		}
	}

	/** Advances playback, updates the instance layers, and evaluates the pose. */
	public function advance(seconds:Float):Void
		stepPlayer(seconds, true);

	/**
	 * Like `advance`, but evaluates the pose only: joint matrices are current and the deformed geometry is not
	 * touched. For measuring what a pose would be (planning a reach) without paying to skin it.
	 */
	public function pose(seconds:Float = 0.0):Void
		stepPlayer(seconds, false);

	function stepPlayer(seconds:Float, skin:Bool):Void {
		var step = seconds * speed;
		time += step;
		if (outgoing.length > 0) {
			fadeElapsed += seconds;
			for (entry in outgoing) entry.time += step;
			if (fadeElapsed >= fadeDuration) outgoing.resize(0);
		}
		if (overlayClip >= 0) overlayTime += step;
		var weight = currentWeight(), base = 1.0 - overlayWeight;
		instance.setLayer(0, clip, time, weight * base, loop);
		for (index in 0...MAX_OUTGOING) {
			if (index < outgoing.length) {
				var entry = outgoing[index];
				instance.setLayer(index + 1, entry.clip, entry.time, entry.share * (1.0 - weight) * base, entry.loop);
			} else
				instance.setLayer(index + 1, -1, 0.0, 0.0);
		}
		if (overlayClip >= 0 && overlayWeight > 0.0) instance.setLayer(OVERLAY_LAYER, overlayClip, overlayHold == null ? overlayTime : overlayHold, overlayWeight);
		else instance.setLayer(OVERLAY_LAYER, -1, 0.0, 0.0);
		if (skin) instance.evaluate();
		else instance.evaluatePose();
	}
}
