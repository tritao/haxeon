import haxe.io.Bytes;
import haxeon.animation.AnimationAsset;
import haxeon.animation.AnimationInstance;
import haxeon.animation.ClipPlayer;
import haxeon.animation.rig.HumanBone;
import haxeon.animation.rig.HumanBones;
import haxeon.animation.rig.HumanPose;
import haxeon.animation.rig.HumanoidRig;
import haxeon.animation.rig.RigMapping;

class AnimationSmoke {
    static function check(ok:Bool, message:String):Void {
        if (!ok) throw message;
    }

    static function main():Void {
        var fixture:Null<String> = null;
        for (candidate in ["assets/character-soldier.glb", "packages/animation/tests/assets/character-soldier.glb",
            "haxeon/packages/animation/tests/assets/character-soldier.glb"])
            if (sys.FileSystem.exists(candidate)) fixture = candidate;
        if (fixture == null) throw "Run the smoke test from the repository or package test directory";
        var asset = AnimationAsset.load(fixture);
        var instance = new AnimationInstance(asset);
        var player = new ClipPlayer(instance);
        check(player.playNamed("walk"), "walk clip missing");
        var before = instance.readPositions(0);
        player.pose(0.2);
        check(before.compare(instance.readPositions(0)) == 0, "pose-only evaluation skinned vertices");
        check(instance.readSkinMatrices(0).length == asset.readSkinJoints(0).length * 16,
            "skin palette does not match its joint mapping");
        check(asset.readBindPositions(0).length == asset.primitives[0].vertexCount * 12, "bind positions");
        check(asset.readJointWeights(0).length == asset.primitives[0].vertexCount * 16, "four weights");
        instance.evaluate();
        check(before.compare(instance.readPositions(0)) != 0, "walk did not deform mesh");
        player.playNamed("idle");
        player.pose(0.1);
        check(player.fading(), "crossfade missing");
        asset.dispose();
        player.pose(0.1);
        check(instance.readSkinMatrices(0).length > 0, "instance lost released asset");
        instance.dispose();
        instance.dispose();

        // A namespaced humanoid rig exercises the shared mapping and pose layer without SceneKit.
        var names = ["Hips", "Spine2", "Neck", "Head", "LeftArm", "LeftForeArm", "LeftHand",
            "RightArm", "RightForeArm", "RightHand", "LeftUpLeg", "LeftLeg", "LeftFoot",
            "RightUpLeg", "RightLeg", "RightFoot"];
        var nodes = [for (i in 0...names.length) {name: "mixamorig:" + names[i], translation: [0.0, i * 0.1, 0.0]}];
        var document = haxe.Json.stringify({asset: {version: "2.0"}, scene: 0,
            scenes: [{nodes: [for (i in 0...names.length) i]}], nodes: nodes});
        var human = AnimationAsset.fromBytes(Bytes.ofString(document));
        var rig = HumanoidRig.detect(human);
        check(rig.mapping.name == "mixamo", "namespaced rig detection");
        for (bone in HumanBones.REQUIRED) check(rig.has(bone), "missing required bone");
        var posed = new AnimationInstance(human);
        var pose = new HumanPose(rig, posed.readJointMatrices());
        var head = pose.bonePosition(HumanBone.Head);
        check(Math.abs(head[2] - 0.3) < 0.001, "humanoid landmark axis conversion");
        var hand = pose.boneFrame(HumanBone.HandR);
        if (hand == null) throw "missing hand frame";
        check(hand.length == 16, "hand frame");
        posed.dispose();
        human.dispose();
        Sys.println("animation smoke: ok");
    }
}
