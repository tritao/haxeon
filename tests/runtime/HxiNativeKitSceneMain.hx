import compiler.Compiler;
import compiler.hl.HlWriter;
import compiler.runtime.CompilerIntrinsics;
import sys.io.File;

class HxiNativeKitSceneMain {
	static function main():Void {
		var output = Sys.args()[0],
			sceneHxi = File.getContent(Sys.args()[1]),
			renderHxi = File.getContent(Sys.args()[2]),
			nativekitRoot = Sys.args()[3],
			nativekitHxi = File.getContent(Sys.args()[4]),
			gpuHxi = File.getContent(Sys.args()[5]),
			compiler = new Compiler();
		CompilerIntrinsics.register(compiler);
		compiler.addSourceRoot(Sys.getCwd() + "/stdlib");
		compiler.addSourceRoot(nativekitRoot + "/bindings/haxe");
		compiler.addSourceRoot(nativekitRoot + "/modules/gpu/bindings/haxe");
		compiler.addSourceRoot(nativekitRoot + "/modules/scene_render/bindings/haxe");
		compiler.update("NativeKitWindow.hx", File.getContent(nativekitRoot + "/bindings/haxe/NativeKitWindow.hx"));
		compiler.addFfiProjection("NativeKit.hxmap", File.getContent(nativekitRoot + "/bindings/haxe/nativekit.hxmap"));
		compiler.addFfiProjection("NativeKitGpu.hxmap", File.getContent(nativekitRoot + "/modules/gpu/bindings/nativekit-gpu.hxmap"));
		compiler.addFfiProjection("NativeKitSceneRender.hxmap", File.getContent(nativekitRoot + "/modules/scene_render/bindings/nativekit-scene-render.hxmap"));
		compiler.addFfiInterface("NativeKit.hxi", nativekitHxi);
		compiler.addFfiInterface("NativeKitGpu.hxi", gpuHxi);
		compiler.addFfiInterface("NativeKitScene.hxi", sceneHxi);
		compiler.addFfiInterface("NativeKitSceneRender.hxi", renderHxi);
		compiler.update("Main.hx", source());
		File.saveBytes(output, HlWriter.encode(compiler.compile("Main").module));
	}

	static function source():String return '
import NativeKitScene;
import NativeKitSceneRender;
import nativekit.scene.SceneRenderer;

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

		var sceneRenderer = SceneRenderer.createHeadless(),
			execution = sceneRenderer.render(snapshot, view);
		if (haxe.Int64.toInt(execution.get_commands()) != 1
			|| haxe.Int64.toInt(execution.get_draw_calls()) != 1
			|| haxe.Int64.toInt(execution.get_geometry_resources_created()) != 1) return 10;

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
			movedExecution = sceneRenderer.render(movedSnapshot, view, movedChanges),
			update = sceneRenderer.lastUpdate();
		if (update == null
			|| update.get_plan_rebuilt() != 0
			|| haxe.Int64.toInt(update.get_patched_instances()) != 1
			|| haxe.Int64.toInt(update.get_updated_geometry_resources()) != 0
			|| haxe.Int64.toInt(movedExecution.get_commands()) != 1) return 16;

		sceneRenderer.dispose();
		movedSnapshotOwner.close();
		movedChangesOwner.close();
		snapshotOwner.close();
		changesOwner.close();
		sceneOwner.close();
		return 42;
	}
}
';
}
