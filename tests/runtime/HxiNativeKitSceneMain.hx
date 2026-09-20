import compiler.Compiler;
import compiler.hl.HlWriter;
import compiler.runtime.CompilerIntrinsics;
import sys.io.File;

class HxiNativeKitSceneMain {
	static function main():Void {
		var output = Sys.args()[0],
			sceneHxi = File.getContent(Sys.args()[1]),
			renderHxi = File.getContent(Sys.args()[2]),
			compiler = new Compiler();
		CompilerIntrinsics.register(compiler);
		compiler.addSourceRoot(Sys.getCwd() + "/stdlib");
		compiler.addFfiInterface("NativeKitScene.hxi", sceneHxi);
		compiler.addFfiInterface("NativeKitSceneRender.hxi", renderHxi);
		compiler.update("Main.hx", source());
		File.saveBytes(output, HlWriter.encode(compiler.compile("Main").module));
	}

	static function source():String return '
import NativeKitScene;
import NativeKitSceneRender;

class Main {
	static function main():Int {
		var sceneResult = NativeKitScene.nkscene_scene_create();
		if (sceneResult.status != NativeKitSceneConstants.NKS_OK) return 1;
		var sceneOwner = sceneResult.out_scene,
			scene = sceneOwner.borrow();

		var geometryResult = NativeKitScene.nkscene_geometry_create(scene);
		if (geometryResult.status != NativeKitSceneConstants.NKS_OK) return 2;
		var materialResult = NativeKitScene.nkscene_material_create(scene);
		if (materialResult.status != NativeKitSceneConstants.NKS_OK) return 3;

		var transactionResult = NativeKitScene.nkscene_transaction_begin(scene);
		if (transactionResult.status != NativeKitSceneConstants.NKS_OK) return 4;
		var transactionOwner = transactionResult.out_transaction,
			transaction = transactionOwner.borrow(),
			occurrence = new nkscene_occurrence_id();
		if (NativeKitScene.nkscene_tx_create_occurrence(transaction, occurrence) != NativeKitSceneConstants.NKS_OK) return 5;
		if (NativeKitScene.nkscene_tx_set_geometry(transaction, occurrence, geometryResult.out_geometry) != NativeKitSceneConstants.NKS_OK) return 6;
		if (NativeKitScene.nkscene_tx_set_material(transaction, occurrence, materialResult.out_material) != NativeKitSceneConstants.NKS_OK) return 7;
		var changesResult = NativeKitScene.nkscene_transaction_commit_with_changes(transaction);
		if (changesResult.status != NativeKitSceneConstants.NKS_OK) return 8;
		transactionOwner.close();
		var changesOwner = changesResult.out_changes,
			changes = changesOwner.borrow(),
			snapshotResult = NativeKitScene.nkscene_scene_snapshot(scene);
		if (snapshotResult.status != NativeKitSceneConstants.NKS_OK) return 9;
		var snapshotOwner = snapshotResult.out_snapshot,
			snapshot = snapshotOwner.borrow(),
			view = new nkscene_render_view();
		view.set_struct_size(nkscene_render_view.size());

		var planResult = NativeKitSceneRender.nkscene_render_plan_compile(snapshot, view);
		if (planResult.status != NativeKitSceneConstants.NKS_OK) return 10;
		var planOwner = planResult.out_plan,
			plan = planOwner.borrow(),
			countResult = NativeKitSceneRender.nkscene_render_plan_get_item_count(plan);
		if (countResult.status != NativeKitSceneConstants.NKS_OK || haxe.Int64.toInt(countResult.out_count) != 1) return 11;

		var movedTransactionResult = NativeKitScene.nkscene_transaction_begin(scene);
		if (movedTransactionResult.status != NativeKitSceneConstants.NKS_OK) return 12;
		var movedTransactionOwner = movedTransactionResult.out_transaction,
			movedTransaction = movedTransactionOwner.borrow(),
			transform = new nkscene_transform();
		if (NativeKitScene.nkscene_tx_set_transform(movedTransaction, occurrence, transform) != NativeKitSceneConstants.NKS_OK) return 13;
		var movedChangesResult = NativeKitScene.nkscene_transaction_commit_with_changes(movedTransaction);
		if (movedChangesResult.status != NativeKitSceneConstants.NKS_OK) return 14;
		movedTransactionOwner.close();
		var movedChangesOwner = movedChangesResult.out_changes,
			movedChanges = movedChangesOwner.borrow(),
			movedSnapshotResult = NativeKitScene.nkscene_scene_snapshot(scene);
		if (movedSnapshotResult.status != NativeKitSceneConstants.NKS_OK) return 15;
		var movedSnapshotOwner = movedSnapshotResult.out_snapshot,
			movedSnapshot = movedSnapshotOwner.borrow(),
			update = new nkscene_render_update();
		update.set_struct_size(nkscene_render_update.size());
		var updateResult = NativeKitSceneRender.nkscene_render_plan_update(
			plan, movedSnapshot, movedChanges, view, update);
		if (updateResult.status != NativeKitSceneConstants.NKS_OK
			|| updateResult.out_update.get_plan_rebuilt() != 0
			|| haxe.Int64.toInt(updateResult.out_update.get_patched_instances()) != 1
			|| haxe.Int64.toInt(updateResult.out_update.get_updated_geometry_resources()) != 0) return 16;

		movedSnapshotOwner.close();
		movedChangesOwner.close();
		planOwner.close();
		snapshotOwner.close();
		changesOwner.close();
		sceneOwner.close();
		return 42;
	}
}
';
}
