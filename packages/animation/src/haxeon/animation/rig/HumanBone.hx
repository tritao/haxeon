package haxeon.animation.rig;

/**
 * the standard humanoid bones. The finger bones name the knuckle at the
 * base of each finger's first segment. Asset rigs map onto these names once at
 * import, so everything above AnimKit is independent of any asset's naming.
 * The names describe anatomy only; an asset's own hierarchy may differ.
 */
enum abstract HumanBone(String) from String to String {
	var Pelvis = "pelvis";
	var Spine = "spine";
	var Spine2 = "spine2";
	var Chest = "chest";
	var Neck = "neck";
	var Head = "head";
	var ShoulderL = "shoulder.L";
	var UpperArmL = "upper_arm.L";
	var ForearmL = "forearm.L";
	var HandL = "hand.L";
	var IndexL = "index1.L";
	var MiddleL = "middle1.L";
	var PinkyL = "pinky1.L";
	var ShoulderR = "shoulder.R";
	var UpperArmR = "upper_arm.R";
	var ForearmR = "forearm.R";
	var HandR = "hand.R";
	var IndexR = "index1.R";
	var MiddleR = "middle1.R";
	var PinkyR = "pinky1.R";
	var ThighL = "thigh.L";
	var ShinL = "shin.L";
	var FootL = "foot.L";
	var ToeL = "toe.L";
	/** Tip of the left foot, where the toes end. */
	var ToeTipL = "toe_tip.L";
	var ThighR = "thigh.R";
	var ShinR = "shin.R";
	var FootR = "foot.R";
	var ToeR = "toe.R";
	var ToeTipR = "toe_tip.R";
}
