import nativekit.ffi.NativeKit;
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
		compiler.addSourceRoot(nativekitRoot + "/modules/scene/bindings/haxe");
		compiler.addSourceRoot(nativekitRoot + "/modules/scene_render/bindings/haxe");
		compiler.update("NativeKitWindow.hx", File.getContent(nativekitRoot + "/bindings/haxe/NativeKitWindow.hx"));
		compiler.addFfiProjection("NativeKit.hxmap", File.getContent(nativekitRoot + "/bindings/haxe/nativekit.hxmap"));
		compiler.addFfiProjection("NativeKitGpu.hxmap", File.getContent(nativekitRoot + "/modules/gpu/bindings/nativekit-gpu.hxmap"));
		compiler.addFfiProjection("NativeKitSceneRender.hxmap", File.getContent(nativekitRoot
			+ "/modules/scene_render/bindings/nativekit-scene-render.hxmap"));
		compiler.addFfiInterface("NativeKit.hxi", nativekitHxi);
		compiler.addFfiInterface("NativeKitGpu.hxi", gpuHxi);
		compiler.addFfiInterface("NativeKitScene.hxi", sceneHxi);
		compiler.addFfiInterface("NativeKitSceneRender.hxi", renderHxi);
		compiler.update("Main.hx", source());
		File.saveBytes(output, HlWriter.encode(compiler.compile("Main").module));
	}

	static function source():String
		return '
import NativeKitScene;
import NativeKitSceneRender;
import nativekit.ffi.NativeKitGpu;
import nativekit.ffi.NativeKit;
import NativeKitEventValue;
import NativeKitRuntime;
import nativekit.scene.Scene;
import nativekit.scene.SceneView;
import nativekit.scene.SceneRenderer;
import nativekit.gpu.Renderer;
import nativekit.gpu.Surface;
import haxe.io.Bytes;

class Main {
	static function main():Int {
		var scene = Scene.create(),
			geometry = scene.createGeometry(),
			material = scene.createMaterial();

		var vertex0 = new nkscene_geometry_vertex();
		vertex0.set_position(0, -0.6);
		vertex0.set_position(1, -0.6);
		vertex0.set_position(2, 0.0);
		var vertex1 = new nkscene_geometry_vertex();
		vertex1.set_position(0, 0.6);
		vertex1.set_position(1, -0.6);
		vertex1.set_position(2, 0.0);
		var vertex2 = new nkscene_geometry_vertex();
		vertex2.set_position(0, 0.0);
		vertex2.set_position(1, 0.6);
		vertex2.set_position(2, 0.0);
		var geometryData = new nkscene_geometry_data();
		geometryData.set_vertices([vertex0, vertex1, vertex2]);
		var indexBytes = Bytes.alloc(12);
		indexBytes.setInt32(0, 0);
		indexBytes.setInt32(4, 1);
		indexBytes.setInt32(8, 2);
		geometryData.set_indices_bytes(indexBytes);
		geometryData.set_index_count(3);
		var bounds = new nkscene_bounds();
		bounds.set_minimum(0, -0.6);
		bounds.set_minimum(1, -0.6);
		bounds.set_minimum(2, 0.0);
		bounds.set_maximum(0, 0.6);
		bounds.set_maximum(1, 0.6);
		bounds.set_maximum(2, 0.0);
		bounds.set_valid(1);
		geometryData.set_bounds(bounds);
		var subelement = new nkscene_subelement_range();
		subelement.set_first_primitive(0);
		subelement.set_primitive_count(1);
		subelement.set_subelement(42);
		geometryData.set_subelements([subelement]);
		scene.setGeometryData(geometry, geometryData);
		var materialData = new nkscene_material_data();
		materialData.set_base_color(0, 0.2);
		materialData.set_base_color(1, 0.7);
		materialData.set_base_color(2, 1.0);
		materialData.set_base_color(3, 1.0);
		materialData.set_opacity(1.0);
		materialData.set_flags(NativeKitSceneConstants.NKS_MATERIAL_OPAQUE);
		scene.setMaterialData(material, materialData);

		var transaction = scene.beginTransaction(),
			occurrence = transaction.createOccurrence();
		transaction.setGeometry(occurrence, geometry);
		transaction.setMaterial(occurrence, material);
		var changes = transaction.commitWithChanges(),
			snapshot = scene.snapshot(),
			view = new SceneView();

		var sceneRenderer = SceneRenderer.createHeadless(),
			execution = sceneRenderer.render(snapshot, view);
		if (haxe.Int64.toInt(execution.get_commands()) != 1
			|| haxe.Int64.toInt(execution.get_draw_calls()) != 1
			|| haxe.Int64.toInt(execution.get_geometry_resources_created()) != 1) return 11;
		var hiddenView = new SceneView();
		hiddenView.setVisibility(occurrence, false);
		var hiddenExecution = sceneRenderer.render(snapshot, hiddenView),
			hiddenUpdate = sceneRenderer.lastUpdate();
		if (hiddenView.visibilityOverrideCount() != 1
			|| hiddenUpdate == null
			|| hiddenUpdate.get_plan_rebuilt() != 1
			|| haxe.Int64.toInt(hiddenExecution.get_commands()) != 0) return 12;
		var materialView = new SceneView();
		materialView.setMaterial(occurrence, material);
		var materialExecution = sceneRenderer.render(snapshot, materialView),
			materialUpdate = sceneRenderer.lastUpdate();
		if (materialView.materialOverrideCount() != 1
			|| materialUpdate == null
			|| materialUpdate.get_plan_rebuilt() != 1
			|| haxe.Int64.toInt(materialExecution.get_commands()) != 1) return 13;
		var refreshView = new SceneView();
		refreshView.setIncludeInvisible(true);
		var refreshedExecution = sceneRenderer.render(snapshot, refreshView),
			refreshed = sceneRenderer.lastUpdate();
		if (refreshed == null || refreshed.get_plan_rebuilt() != 1
			|| haxe.Int64.toInt(refreshedExecution.get_commands()) != 1) return 14;
		view.setIncludeInvisible(true);

		var movedTransaction = scene.beginTransaction(),
			transform = new nkscene_transform();
		transform.set_matrix(0, 1.0);
		transform.set_matrix(5, 1.0);
		transform.set_matrix(10, 1.0);
		transform.set_matrix(15, 1.0);
		transform.set_matrix(12, 0.1);
		movedTransaction.setTransform(occurrence, transform);
		var movedChanges = movedTransaction.commitWithChanges(),
			movedSnapshot = scene.snapshot(),
			movedExecution = sceneRenderer.render(movedSnapshot, view, movedChanges),
			update = sceneRenderer.lastUpdate();
		if (update == null
			|| update.get_plan_rebuilt() != 0
			|| haxe.Int64.toInt(update.get_patched_instances()) != 1
			|| haxe.Int64.toInt(update.get_updated_geometry_resources()) != 0
			|| haxe.Int64.toInt(movedExecution.get_commands()) != 1) return 17;

		var realRuntime = NativeKitRuntime.start(),
			windowOptions = new WindowOptions();
		windowOptions.set_width(64);
		windowOptions.set_height(64);
		windowOptions.set_title("Haxeon: NativeKit scene renderer");
		windowOptions.set_flags(WindowFlags.Resizable);
		windowOptions.set_owner(WindowHandle.invalid());
		windowOptions.set_kind(WindowKind.Normal);
		var window = realRuntime.createWindow(windowOptions),
			surface = Surface.create(window, 64, 64),
			ready = false,
			subscription = realRuntime.events.listen(function(value) switch value {
				case SurfaceReady(source) if (source.rawValue() == surface.nativeHandle().rawValue()):
					ready = true;
				case _:
			});
		var deadline = Sys.time() + 5.0;
		while (!ready && Sys.time() < deadline)
			realRuntime.events.poll();
		if (!ready) return 18;
		var renderer:Renderer = surface.createRenderer(),
			realSceneRenderer = SceneRenderer.create(renderer),
			realExecution = realSceneRenderer.render(snapshot, view);
		if (realExecution.get_result() != NativeKitGpu.GpuStatus.Ok
			|| haxe.Int64.toInt(realExecution.get_commands()) != 1
			|| haxe.Int64.toInt(realExecution.get_draw_calls()) != 1
			|| haxe.Int64.toInt(realExecution.get_geometry_resources_created()) != 1) return 19;
		var realMovedExecution = realSceneRenderer.render(movedSnapshot, view, movedChanges);
		if (realMovedExecution.get_result() != NativeKitGpu.GpuStatus.Ok
			|| haxe.Int64.toInt(realMovedExecution.get_commands()) != 1
			|| haxe.Int64.toInt(realMovedExecution.get_draw_calls()) != 1
			|| haxe.Int64.toInt(realMovedExecution.get_geometry_resources_created()) != 0
			|| haxe.Int64.toInt(realMovedExecution.get_geometry_resources_updated()) != 0
			|| haxe.Int64.toInt(realMovedExecution.get_instance_records_updated()) != 1) return 20;
		var picked = realSceneRenderer.pickPixel(movedSnapshot, 64, 64, 32, 32);
		if (picked.get_occurrence().get_value() != occurrence.get_value()
			|| picked.get_subelement() != 42) {
			return 21;
		}
		realSceneRenderer.dispose();
		subscription.dispose();
		renderer.dispose();
		surface.dispose();
		realRuntime.dispose();

		sceneRenderer.dispose();
		movedSnapshot.dispose();
		movedChanges.dispose();
		snapshot.dispose();
		changes.dispose();
		scene.dispose();
		return 42;
	}
}
';
}
