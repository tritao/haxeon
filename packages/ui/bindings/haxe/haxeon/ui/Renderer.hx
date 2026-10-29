package haxeon.ui;

import nativekit.ffi.NativeKitTypes;
import nativekit.ffi.NativeKit;
import NativeKitUI;

/** Typed renderer facade for retained UI display lists. */
class Renderer {
	var value:nkui_renderer;
	var disposed:Bool;

	private function new(value:nkui_renderer) {
		this.value = value;
		disposed = false;
	}

	public static function create():Renderer {
		var made = NativeKitUI.nkui_renderer_create();
		UiResult.check(made.status, "renderer.create");
		return new Renderer(made.out_renderer);
	}

	/** Prepares the native backend and returns its borrowed GPU renderer. */
	public function prepare(surface:Surface):Int {
		ensureLive();
		UiResult.check(NativeKitUI.nkui_renderer_prepare(value, surface.nativeHandle()),
			"renderer.prepare");
		var borrowed = NativeKitUI.nkui_renderer_get_gpu_renderer(value);
		UiResult.check(borrowed.status, "renderer.gpuRenderer");
		return borrowed.out_gpu_renderer_id;
	}

	public function render(list:DisplayList, surface:Surface):Void {
		ensureLive();
		UiResult.check(NativeKitUI.nkui_renderer_render(value, list.nativeHandle(), surface.nativeHandle()), "renderer.render");
	}

	public function renderFrame(list:DisplayList, surface:Surface, frame:FrameInfo):Void {
		ensureLive();
		UiResult.check(NativeKitUI.nkui_renderer_render_frame(value, list.nativeHandle(), surface.nativeHandle(), frame.nativeValue()), "renderer.renderFrame");
	}

	/** Composites a display list over contents already rendered in the current frame. */
	public function renderFrameOverlay(list:DisplayList, surface:Surface, frame:FrameInfo):Void {
		ensureLive();
		UiResult.check(NativeKitUI.nkui_renderer_render_frame_overlay(value, list.nativeHandle(),
			surface.nativeHandle(), frame.nativeValue()), "renderer.renderFrameOverlay");
	}

	/** Registers a native-owned shader implementation for a custom effect. */
	public function registerCustomEffect(registration:CustomEffectRegistration):Void {
		ensureLive();
		if (registration == null)
			throw "Custom effect registration is required";
		UiResult.check(NativeKitUI.nkui_renderer_register_custom_effect(value,
			registration.nativeValue()), "renderer.registerCustomEffect");
	}

	public function stats():RendererStats {
		ensureLive();
		var result = NativeKitUI.nkui_renderer_get_stats(value);
		UiResult.check(result.status, "renderer.stats");
		var stats = result.out_stats;
		return new RendererStats(stats.get_path_preparations(), stats.get_path_cache_hits(), stats.get_path_cache_misses(),
			stats.get_path_vertices_generated(), stats.get_path_geometry_bytes_allocated(), stats.get_path_tessellation_nanoseconds(),
			stats.get_path_geometry_bytes_retained(), stats.get_raster_cache_hits(), stats.get_raster_cache_misses(),
			stats.get_raster_cache_entries(), stats.get_raster_cache_bytes());
	}

	/** How often layout-session frames compiled a render plan or reused the last one, and why each compile was needed.
		Cumulative; the reasons add up to `compiles`. */
	public function planReuse():RenderPlanReuse {
		ensureLive();
		var result = NativeKitUI.nkui_renderer_get_stats(value);
		UiResult.check(result.status, "renderer.planReuse");
		var stats = result.out_stats;
		return new RenderPlanReuse(haxe.Int64.toFloat(stats.get_render_plan_compiles()), haxe.Int64.toFloat(stats.get_render_plan_reuses()),
			haxe.Int64.toFloat(stats.get_render_plan_miss_epoch()), haxe.Int64.toFloat(stats.get_render_plan_miss_frame()),
			haxe.Int64.toFloat(stats.get_render_plan_miss_lists()), haxe.Int64.toFloat(stats.get_render_plan_miss_dependencies()),
			haxe.Int64.toFloat(stats.get_render_plan_miss_atlas()), haxe.Int64.toFloat(stats.get_render_plan_miss_unsettled()));
	}

	var gpuFrameTiming = false;

	/** Measures the GPU time of the renderer's frames while enabled. Off by default; cheap to call each frame. */
	public function setGpuFrameTiming(enabled:Bool):Void {
		if (enabled == gpuFrameTiming)
			return;
		ensureLive();
		UiResult.check(NativeKitUI.nkui_renderer_set_gpu_frame_timing(value, enabled ? 1 : 0), "renderer.setGpuFrameTiming");
		gpuFrameTiming = enabled;
	}

	/** GPU time of the newest measured frame in nanoseconds, as of the last pollGpuFrameTime. */
	public var gpuFrameNanoseconds(default, null):Float = 0;

	var gpuTimedFrames:haxe.Int64 = 0;

	/** Reads the newest GPU frame time while timing is enabled; true when a result arrived since the last poll. A result
		belongs to a frame a few frames back. */
	public function pollGpuFrameTime():Bool {
		ensureLive();
		var result = NativeKitUI.nkui_renderer_get_gpu_frame_time(value);
		UiResult.check(result.status, "renderer.pollGpuFrameTime");
		if (result.out_timed_frames == gpuTimedFrames)
			return false;
		gpuTimedFrames = result.out_timed_frames;
		gpuFrameNanoseconds = haxe.Int64.toFloat(result.out_nanoseconds);
		return true;
	}

	/** Releases the renderer and its backend resources. Repeated disposal is safe. */
	public function dispose():Void {
		if (disposed)
			return;
		var status = NativeKitUI.nkui_renderer_destroy(value);
		disposed = true;
		UiResult.check(status, "renderer.dispose");
	}

	public function isDisposed():Bool
		return disposed;

	@:allow(LayoutSession)
	private function nativeHandle():nkui_renderer {
		ensureLive();
		return value;
	}

	function ensureLive():Void {
		if (disposed)
			throw "Renderer has been disposed";
	}
}

/** Cumulative render plan compile and reuse counts, with the reason for each compile. */
class RenderPlanReuse {
	public final compiles:Float;
	public final reuses:Float;
	/** The session's layout changed. */
	public final missEpoch:Float;
	/** The frame size, scale, target or load mode changed. */
	public final missFrame:Float;
	/** A custom paint list, composite or cache policy changed. */
	public final missLists:Float;
	/** A text layout or render target the plan read changed. */
	public final missDependencies:Float;
	/** The session text engine's atlas, layout or fonts changed. */
	public final missAtlas:Float;
	/** The first plan, or one not yet confirmed by a second identical build. */
	public final missUnsettled:Float;

	public function new(compiles:Float, reuses:Float, missEpoch:Float, missFrame:Float, missLists:Float, missDependencies:Float, missAtlas:Float,
			missUnsettled:Float) {
		this.compiles = compiles;
		this.reuses = reuses;
		this.missEpoch = missEpoch;
		this.missFrame = missFrame;
		this.missLists = missLists;
		this.missDependencies = missDependencies;
		this.missAtlas = missAtlas;
		this.missUnsettled = missUnsettled;
	}
}

/** Immutable renderer preparation counters. */
class RendererStats {
	public final pathPreparations:haxe.Int64;
	public final pathCacheHits:haxe.Int64;
	public final pathCacheMisses:haxe.Int64;
	public final pathVerticesGenerated:haxe.Int64;
	public final pathGeometryBytesAllocated:haxe.Int64;
	public final pathTessellationNanoseconds:haxe.Int64;
	public final pathGeometryBytesRetained:haxe.Int64;
	public final rasterCacheHits:haxe.Int64;
	public final rasterCacheMisses:haxe.Int64;
	public final rasterCacheEntries:haxe.Int64;
	public final rasterCacheBytes:haxe.Int64;

	public function new(pathPreparations:haxe.Int64, pathCacheHits:haxe.Int64, pathCacheMisses:haxe.Int64, pathVerticesGenerated:haxe.Int64,
		pathGeometryBytesAllocated:haxe.Int64, pathTessellationNanoseconds:haxe.Int64, pathGeometryBytesRetained:haxe.Int64,
		rasterCacheHits:haxe.Int64, rasterCacheMisses:haxe.Int64, rasterCacheEntries:haxe.Int64,
		rasterCacheBytes:haxe.Int64) {
		this.pathPreparations = pathPreparations;
		this.pathCacheHits = pathCacheHits;
		this.pathCacheMisses = pathCacheMisses;
		this.pathVerticesGenerated = pathVerticesGenerated;
		this.pathGeometryBytesAllocated = pathGeometryBytesAllocated;
		this.pathTessellationNanoseconds = pathTessellationNanoseconds;
		this.pathGeometryBytesRetained = pathGeometryBytesRetained;
		this.rasterCacheHits = rasterCacheHits;
		this.rasterCacheMisses = rasterCacheMisses;
		this.rasterCacheEntries = rasterCacheEntries;
		this.rasterCacheBytes = rasterCacheBytes;
	}
}
