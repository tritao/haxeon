package haxeon.animation.rig;

/**
 * the standard humanoid bones. The finger bones name the knuckle at the
 * base of each finger's first segment. Asset rigs map onto these names once at
 * import, so everything above AnimKit is independent of any asset's naming.
 * The names describe anatomy only; an asset's own hierarchy may differ.
 */
enum HumanBone:String {
	/** The hips, the root of the skeleton. */
	Pelvis = "pelvis";

	/** The lower spine. */
	Spine = "spine";

	/** The middle spine. */
	Spine2 = "spine2";

	/** The upper spine. */
	Chest = "chest";

	/** The neck. */
	Neck = "neck";

	/** The head. */
	Head = "head";

	/** The left shoulder (clavicle). */
	ShoulderL = "shoulder.L";

	/** The left upper arm. */
	UpperArmL = "upper_arm.L";

	/** The left forearm. */
	ForearmL = "forearm.L";

	/** The left hand. */
	HandL = "hand.L";

	/** The left index finger's first joint. */
	IndexL = "index1.L";

	/** The left middle finger's first joint. */
	MiddleL = "middle1.L";

	/** The left little finger's first joint. */
	PinkyL = "pinky1.L";

	/** The right shoulder (clavicle). */
	ShoulderR = "shoulder.R";

	/** The right upper arm. */
	UpperArmR = "upper_arm.R";

	/** The right forearm. */
	ForearmR = "forearm.R";

	/** The right hand. */
	HandR = "hand.R";

	/** The right index finger's first joint. */
	IndexR = "index1.R";

	/** The right middle finger's first joint. */
	MiddleR = "middle1.R";

	/** The right little finger's first joint. */
	PinkyR = "pinky1.R";

	/** The left thigh. */
	ThighL = "thigh.L";

	/** The left shin. */
	ShinL = "shin.L";

	/** The left foot. */
	FootL = "foot.L";

	/** The left toes. */
	ToeL = "toe.L";
	/** Tip of the left foot, where the toes end. */
	ToeTipL = "toe_tip.L";

	/** The right thigh. */
	ThighR = "thigh.R";

	/** The right shin. */
	ShinR = "shin.R";

	/** The right foot. */
	FootR = "foot.R";

	/** The right toes. */
	ToeR = "toe.R";

	/** The tip of the right toes. */
	ToeTipR = "toe_tip.R";

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
