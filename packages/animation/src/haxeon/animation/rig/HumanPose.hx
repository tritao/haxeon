package haxeon.animation.rig;

import haxe.io.Bytes;

/**
 * Standard-bone view of an animation instance's joint matrices, in the
 * model's space (+Z up, +X forward, metres).
 *
 * Hands expose a rig-independent frame: the origin is the palm centre, +X
 * points along the fingers, +Y towards the thumb side, and +Z completes a
 * right-handed frame, so it leaves the two hands through opposite faces. It is
 * derived from the rest pose knuckles, so grip offsets authored once work on
 * every rig. Other bones use their own joint frame with scale removed.
 */
class HumanPose {
	public final rig:HumanoidRig;
	var matrices:Bytes;
	final corrections:Map<String, Array<Float>> = new Map();

	/** restMatrices must be the instance's joint matrices at its rest pose. */
	public function new(rig:HumanoidRig, restMatrices:Bytes) {
		this.rig = rig;
		matrices = restMatrices;
		for (hand in [HumanBone.HandL, HumanBone.HandR]) {
			var canonical = handFrameFromKnuckles(hand);
			if (canonical != null)
				corrections.set(hand, Mat4.multiply(Mat4.rigidInverse(jointFrame(hand)), canonical));
		}
	}

	/** Replaces the pose with an instance's current joint matrices. */
	public function update(jointMatrices:Bytes):Void
		matrices = jointMatrices;

	/** Model-space position of a bone, or null when the rig lacks it. */
	public function bonePosition(bone:HumanBone):Null<Array<Float>> {
		var joint = rig.joint(bone);
		if (joint < 0)
			return null;
		var base = joint * 64;
		return [matrices.getFloat(base + 48), matrices.getFloat(base + 52), matrices.getFloat(base + 56)];
	}

	/** Rigid model-space frame of a bone, or null when the rig lacks it. */
	public function boneFrame(bone:HumanBone):Null<Array<Float>> {
		if (!rig.has(bone))
			return null;
		var frame = jointFrame(bone);
		var correction = corrections.get(bone);
		return correction == null ? frame : Mat4.multiply(frame, correction);
	}

	function jointFrame(bone:HumanBone):Array<Float> {
		var base = rig.joint(bone) * 64;
		return Mat4.orthonormalized([for (i in 0...16) matrices.getFloat(base + i * 4)]);
	}

	function handFrameFromKnuckles(hand:HumanBone):Null<Array<Float>> {
		var left = hand == HumanBone.HandL;
		var wrist = bonePosition(hand);
		var middle = bonePosition(left ? HumanBone.MiddleL : HumanBone.MiddleR);
		var index = bonePosition(left ? HumanBone.IndexL : HumanBone.IndexR);
		var pinky = bonePosition(left ? HumanBone.PinkyL : HumanBone.PinkyR);
		if (wrist == null || middle == null || index == null || pinky == null)
			return null;
		var toMiddle = Mat4.subtract(middle, wrist);
		if (Mat4.dot(toMiddle, toMiddle) < 1e-4)
			return null;
		var x = Mat4.normalize(toMiddle);
		var across = Mat4.subtract(index, pinky);
		var along = Mat4.dot(across, x);
		var side = [across[0] - x[0] * along, across[1] - x[1] * along, across[2] - x[2] * along];
		// Knuckles closer than a millimetre across the hand cannot orient it.
		if (Mat4.dot(side, side) < 1e-6)
			return null;
		var y = Mat4.normalize(side);
		var palm = [(wrist[0] + middle[0]) * 0.5, (wrist[1] + middle[1]) * 0.5, (wrist[2] + middle[2]) * 0.5];
		return Mat4.frame(palm, x, y);
	}
}
