package haxeon.animation.rig;

/**
 * the standard humanoid bones. The finger bones name the knuckle at the
 * base of each finger's first segment. Asset rigs map onto these names once at
 * import, so everything above AnimKit is independent of any asset's naming.
 * The names describe anatomy only; an asset's own hierarchy may differ.
 */
enum abstract HumanBone(String) from String to String {
	/** The hips, the root of the skeleton. */
	var Pelvis = "pelvis";

	/** The lower spine. */
	var Spine = "spine";

	/** The middle spine. */
	var Spine2 = "spine2";

	/** The upper spine. */
	var Chest = "chest";

	/** The neck. */
	var Neck = "neck";

	/** The head. */
	var Head = "head";

	/** The left shoulder (clavicle). */
	var ShoulderL = "shoulder.L";

	/** The left upper arm. */
	var UpperArmL = "upper_arm.L";

	/** The left forearm. */
	var ForearmL = "forearm.L";

	/** The left hand. */
	var HandL = "hand.L";

	/** The left index finger's first joint. */
	var IndexL = "index1.L";

	/** The left middle finger's first joint. */
	var MiddleL = "middle1.L";

	/** The left little finger's first joint. */
	var PinkyL = "pinky1.L";

	/** The right shoulder (clavicle). */
	var ShoulderR = "shoulder.R";

	/** The right upper arm. */
	var UpperArmR = "upper_arm.R";

	/** The right forearm. */
	var ForearmR = "forearm.R";

	/** The right hand. */
	var HandR = "hand.R";

	/** The right index finger's first joint. */
	var IndexR = "index1.R";

	/** The right middle finger's first joint. */
	var MiddleR = "middle1.R";

	/** The right little finger's first joint. */
	var PinkyR = "pinky1.R";

	/** The left thigh. */
	var ThighL = "thigh.L";

	/** The left shin. */
	var ShinL = "shin.L";

	/** The left foot. */
	var FootL = "foot.L";

	/** The left toes. */
	var ToeL = "toe.L";
	/** Tip of the left foot, where the toes end. */
	var ToeTipL = "toe_tip.L";

	/** The right thigh. */
	var ThighR = "thigh.R";

	/** The right shin. */
	var ShinR = "shin.R";

	/** The right foot. */
	var FootR = "foot.R";

	/** The right toes. */
	var ToeR = "toe.R";

	/** The tip of the right toes. */
	var ToeTipR = "toe_tip.R";

	/** Bones every humanoid rig must provide. */
	public static final REQUIRED:Array<HumanBone> = [
		Pelvis,
		Chest,
		Neck,
		Head,
		UpperArmL,
		ForearmL,
		HandL,
		UpperArmR,
		ForearmR,
		HandR,
		ThighL,
		ShinL,
		FootL,
		ThighR,
		ShinR,
		FootR
	];

	/** Bones used when present: spine segments, shoulders, toes, toe tips, and knuckles for hand frames. */
	public static final OPTIONAL:Array<HumanBone> = [
		Spine,
		Spine2,
		ShoulderL,
		ShoulderR,
		IndexL,
		MiddleL,
		PinkyL,
		IndexR,
		MiddleR,
		PinkyR,
		ToeL,
		ToeR,
		ToeTipL,
		ToeTipR
	];

	/** Every bone, the required ones first. */
	public static function all():Array<HumanBone>
		return REQUIRED.concat(OPTIONAL);
}
