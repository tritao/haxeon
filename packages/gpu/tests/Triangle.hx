import haxe.io.Bytes;
import haxeon.gpu.AttachmentAction;
import haxeon.gpu.Buffer;
import haxeon.gpu.BufferDesc;
import haxeon.gpu.CommandBuffer;
import haxeon.gpu.Enums.BufferUsage;
import haxeon.gpu.Enums.Filter;
import haxeon.gpu.Enums.ImageFormat;
import haxeon.gpu.Enums.ImageUsage;
import haxeon.gpu.Enums.IndexType;
import haxeon.gpu.Enums.LoadAction;
import haxeon.gpu.Enums.ReadbackState;
import haxeon.gpu.Enums.ShaderLanguage;
import haxeon.gpu.Enums.ShaderStage;
import haxeon.gpu.Enums.StoreAction;
import haxeon.gpu.Enums.TimestampState;
import haxeon.gpu.Enums.UniformType;
import haxeon.gpu.Enums.VertexFormat;
import haxeon.gpu.Enums.Wrap;
import haxeon.gpu.Image;
import haxeon.gpu.ImageDesc;
import haxeon.gpu.Pipeline;
import haxeon.gpu.Readback;
import haxeon.gpu.RenderPassDesc;
import haxeon.gpu.Renderer;
import haxeon.gpu.Sampler;
import haxeon.gpu.Shader;
import haxeon.gpu.SurfaceOptions as GpuSurfaceOptions;
import haxeon.gpu.Timestamp;
import haxeon.gpu.VertexLayout;
import haxeon.platform.App;
import haxeon.platform.AppLoop;
import haxeon.platform.FrameRecorder;
import haxeon.platform.FrameTick;
import haxeon.platform.GraphicsImageRef;
import haxeon.platform.Runtime;
import haxeon.platform.Surface;
import haxeon.platform.SurfaceFrame;
import haxeon.platform.Window;
import haxeon.platform.event.PlatformEvent;
import nativekit.ffi.NativeKit;
import nativekit.ffi.NativeKitGpu;
import nativekit.ffi.NativeKitTypes;
import nativekit.ffi.NativeKitTypes.WindowOptions as NativeWindowOptions;
import shaders.Fixture;

class Triangle {
	static final vertexLayout = new VertexLayout(28, [
		{slot: 0, bufferIndex: 0, offset: 0, format: VertexFormat.Float2},
		{slot: 1, bufferIndex: 0, offset: 8, format: VertexFormat.Float3},
		{slot: 2, bufferIndex: 0, offset: 20, format: VertexFormat.Float2},
	]);
	@:access(haxeon.platform.AppLoop)
	static function verifyFrameCompletionRecovery(runtime:Runtime, surface:Surface, app:App):Void {
		surface.setFrameMode(SurfaceFrameMode.OnDemand);
		scoped var loop = new AppLoop(runtime.events, surface, app, null);
		var redraws = 0;
		loop.frameSubscription = surface.onFrame(function(_, _) redraws++);
		var source = new Handle(surface.nativeHandle().rawValue());
		var token = haxe.Int64.ofInt(17);
		loop.pending = token;
		runtime.events.dispatch(PlatformEvent.SurfaceFrameComplete(source, token, Result.ErrorCancelled));
		if (loop.pending != null || loop.stopped || loop.failure != null || loop.firstFramePresented)
			throw "A canceled submission stopped the loop or marked a frame as presented";
		var deadline = Sys.monotonicTime() + 5.0;
		while (redraws == 0 && Sys.monotonicTime() < deadline)
			if (!runtime.events.poll()) runtime.events.wait(0.01);
		if (redraws == 0)
			throw "A canceled submission did not request another on-demand frame";
		runtime.events.dispatch(PlatformEvent.SurfaceLost(source));
		loop.pending = token;
		runtime.events.dispatch(PlatformEvent.SurfaceFrameComplete(source, token, Result.ErrorSurfaceLost));
		if (!loop.surfaceLost || loop.stopped || loop.pending != null)
			throw "Surface loss did not pause the loop and release the pending frame";
		loop.draw(1, 1);
		if (loop.lastFrameAt != null)
			throw "The loop tried to draw while its surface was lost";
		runtime.events.dispatch(PlatformEvent.SurfaceReady(source));
		if (loop.surfaceLost || loop.stopped)
			throw "Surface readiness did not resume the loop";
		loop.pending = token;
		runtime.events.dispatch(PlatformEvent.SurfaceFrameComplete(source, token, Result.Ok));
		if (loop.pending != null || loop.stopped || !loop.firstFramePresented)
			throw "The loop did not accept a successful frame after cancellation";
		loop.pending = token;
		runtime.events.dispatch(PlatformEvent.SurfaceFrameComplete(source, token, Result.ErrorUnknown));
		if (loop.pending != null || !loop.stopped || loop.failure == null)
			throw "The loop did not stop on an unexpected rendering error";
	}

	static function verifyGeneratedEnumMembers():Void {
		var vertexFormat:VertexFormat = VertexFormat.Float;
		var floatUniform:UniformType = UniformType.Float;
		var intUniform:UniformType = UniformType.Int;
		if (vertexFormat != VertexFormat.Float || floatUniform != UniformType.Float || intUniform != UniformType.Int)
			throw "generated GPU enum members changed values";
	}

	static function verifyStructuredErrors():Void {
		var caught = false;
		try haxeon.gpu.GpuResult.check(GpuStatus.ErrorInvalidHandle,
			"test.invalidHandle") catch (error:haxeon.platform.PlatformError) {
			caught = error.domain == "nativekit-gpu" && error.code == -3 && error.operation == "test.invalidHandle";
		}
		if (!caught) throw "GPU errors must expose their domain, status, and operation";
		var argument = false;
		try GpuSurfaceOptions.forGpu(0, 0) catch (error:haxeon.platform.BindingError) {
			argument = error.kind == haxeon.platform.BindingErrorKind.InvalidArgument
				&& error.operation == "SurfaceOptions.forGpu";
		}
		if (!argument) throw "GPU argument errors must use BindingError";
	}

	static function createVertexBuffer(renderer:Renderer):Buffer {
		var values = [
			-0.04, 0.04, 1.0, 0.30, 0.35, 0.0, 0.0,
			0.04, 0.04, 0.25, 0.85, 0.55, 2.0, 0.0,
			0.04, -0.04, 0.30, 0.55, 1.0, 2.0, 2.0,
			-0.04, -0.04, 1.0, 0.85, 0.25, 0.0, 2.0
		];
		return Buffer.vertexFloats(renderer, values);
	}

	static function createIndexBuffer(renderer:Renderer):Buffer
		return Buffer.indices16(renderer, [0, 1, 2, 0, 2, 3]);

	static function createCheckerboard(renderer:Renderer):Image {
		var pixels = Bytes.alloc(8 * 8 * 4);
		for (y in 0...8) {
			for (x in 0...8) {
				var bright = ((x + y) & 1) == 0;
				var channel = bright ? 240 : 35;
				var offset = (y * 8 + x) * 4;
				pixels.set(offset, channel);
				pixels.set(offset + 1, channel);
				pixels.set(offset + 2, bright ? 255 : 70);
				pixels.set(offset + 3, 255);
			}
		}
		return Image.fromRgba8(renderer, 8, 8, pixels);
	}

	static function createShader(renderer:Renderer):Shader {
		var builder = Shader.begin(renderer, ShaderLanguage.Glsl,
			"#version 330\nuniform vec2 offset; layout(location=0) in vec2 position; layout(location=1) in vec3 color0; layout(location=2) in vec2 uv0; out vec3 color; out vec2 uv; void main(){color=color0;uv=uv0;gl_Position=vec4(position+offset,0,1);}",
			"#version 330\nuniform sampler2D tex; in vec3 color; in vec2 uv; out vec4 frag_color; void main(){frag_color=texture(tex,uv)*vec4(color,1);}");
		return builder.uniformBlock(0, ShaderStage.Vertex, 16)
			.uniform(0, 0, "offset", UniformType.Float2)
			.texture(0, 0, ShaderStage.Fragment, "tex")
			.build();
	}

	static function createPipeline(renderer:Renderer, shader:Shader):Pipeline
		return Pipeline.begin(renderer, shader, vertexLayout)
			.depthStencil(true)
			.indexType(IndexType.UInt16)
			.build();

	static function applyFrameBindings(pipeline:Pipeline, buffer:Buffer, indexBuffer:Buffer,
			image:Image, sampler:Sampler):Void {
		pipeline.apply();
		buffer.applyVertex(0);
		indexBuffer.applyIndex();
		image.apply(0);
		sampler.apply(0);
	}

	static function drawImmediate(renderer:Renderer):Void {
		for (y in 0...20) {
			for (x in 0...20) {
				renderer.uniforms(16)
					.writeFloat(0, -0.90 + x * 0.095)
					.writeFloat(4, -0.90 + y * 0.095)
					.apply(0);
				renderer.draw(0, 6);
			}
		}
	}

	static function encodeBatched(commandBuffer:CommandBuffer, pipeline:Pipeline, buffer:Buffer,
			indexBuffer:Buffer, image:Image, sampler:Sampler):Void {
		commandBuffer.reset();
		commandBuffer.applyPipeline(pipeline);
		commandBuffer.applyVertexBuffer(0, buffer, 0);
		commandBuffer.applyIndexBuffer(indexBuffer, 0);
		commandBuffer.applyImage(0, image);
		commandBuffer.applySampler(0, sampler);
		commandBuffer.viewport(0, 0, 800, 600);
		commandBuffer.scissor(true, 0, 0, 800, 600);
		for (y in 0...20) {
			for (x in 0...20) {
				commandBuffer.applyUniform2f(0, -0.90 + x * 0.095, -0.90 + y * 0.095);
				commandBuffer.draw(0, 6, 1);
			}
		}
	}

	/** Queries until the GPU finishes the work or a generous deadline passes, sleeping between queries. */
	static function settle<T>(query:Void->T, pending:T->Bool):T {
		var deadline = Sys.monotonicTime() + 5.0;
		var info = query();
		while (pending(info) && Sys.monotonicTime() < deadline) {
			Sys.sleep(0.001);
			info = query();
		}
		return info;
	}

	static function exerciseOptionalFeatures(renderer:Renderer):Void {
		var features = renderer.features();
		var limits = renderer.limits();
		if (features.mrtCount < 1 || limits.maxTextureSize <= 0 || limits.maxColorAttachments < 1)
			throw "GPU capability envelope returned invalid limits";

		if (features.imageReadback) {
			var readbackDesc = new ImageDesc(1, 1, ImageFormat.Rgba8,
				ImageUsage.Sampled | ImageUsage.RenderTarget);
			var readbackImage = Image.create(renderer, readbackDesc);
			var readbackPass = new RenderPassDesc();
			var readbackAction = new AttachmentAction(LoadAction.Clear, StoreAction.Store);
			readbackAction.clearAlpha = 1.0;
			readbackPass.color(readbackImage, readbackAction);
			renderer.beginPassFrame();
			renderer.beginRenderPass(readbackPass);
			renderer.endPass();
			renderer.endFrame();
			var readback = Readback.begin(readbackImage, 0, 0, 1, 1);
			var info = settle(readback.query, info -> info.state == ReadbackState.Pending);
			if (info.state != ReadbackState.Ready || info.size != 4 || info.rowPitch != 4)
				throw "GPU image readback did not become a packed RGBA8 result";
			var pixel = Bytes.alloc(info.size);
			var readSize = readback.read(pixel);
			if (readSize != 4 || pixel.get(3) != 255)
				throw "GPU image readback returned an invalid packed pixel";
			readback.dispose();
			readbackImage.dispose();
		}

		if (features.bufferReadback) {
			var bufferDesc = new BufferDesc(8, BufferUsage.Transfer);
			bufferDesc.dynamicUpdate = true;
			var buffer = Buffer.create(renderer, bufferDesc);
			var expected = Bytes.alloc(8);
			for (index in 0...8)
				expected.set(index, 11 + index * 11);
			buffer.update(0, expected);
			var readback = Readback.beginBuffer(buffer, 2, 4);
			var info = settle(readback.query, info -> info.state == ReadbackState.Pending);
			if (info.state != ReadbackState.Ready || info.size != 4 || info.rowPitch != 4)
				throw "GPU buffer readback did not become a packed range";
			var actual = Bytes.alloc(info.size);
			if (readback.read(actual) != 4 || actual.get(0) != 33 || actual.get(3) != 66)
				throw "GPU buffer readback returned the wrong range";
			readback.dispose();
			buffer.dispose();
		}

		if (features.timestamps) {
			renderer.beginFrame();
			var timestamp = Timestamp.beginNamed(renderer, "triangle");
			timestamp.end();
			renderer.endFrame();
			if (timestamp.label() != "triangle")
				throw "GPU timestamp label was not retained";
			var timestampInfo = settle(timestamp.query, info -> info.state == TimestampState.Pending);
			if (timestampInfo.state != TimestampState.Ready)
				throw "GPU timestamp did not become ready";
			timestamp.dispose();
		}

		if (features.compute && features.storageBuffer) {
			var computeSource = NativeKitGpu.nkgpu_query_graphics_api(renderer.nativeHandle()) == GraphicsApi.OpenglEs
				? "#version 310 es\nlayout(local_size_x=1, local_size_y=1, local_size_z=1) in; layout(std430, binding=0) buffer Data { uint value[]; }; void main(){ value[0] = 1u; }"
				: "#version 430\nlayout(local_size_x=1, local_size_y=1, local_size_z=1) in; layout(std430, binding=0) buffer Data { uint value[]; }; void main(){ value[0] = 1u; }";
			var computeShader = Shader.beginCompute(renderer, ShaderLanguage.Glsl, computeSource)
				.storageBuffer(0, ShaderStage.Compute)
				.build();
			var computePipeline = Pipeline.beginCompute(renderer, computeShader).compute().build();
			var computeBuffer = Buffer.create(renderer, new BufferDesc(4, BufferUsage.Storage));
			renderer.beginPassFrame();
			renderer.beginComputePass();
			computePipeline.apply();
			computeBuffer.applyStorage(0);
			renderer.dispatch(1, 1, 1);
			renderer.endPass();
			renderer.endFrame();
			if (features.bufferReadback) {
				var computeReadback = Readback.beginBuffer(computeBuffer, 0, 4);
				var computeInfo = settle(computeReadback.query, info -> info.state == ReadbackState.Pending);
				var computeBytes = Bytes.alloc(computeInfo.size > 0 ? computeInfo.size : 4);
				if (computeInfo.state != ReadbackState.Ready || computeInfo.size != 4
					|| computeReadback.read(computeBytes) != 4 || computeBytes.get(0) != 1 || computeBytes.get(1) != 0
					|| computeBytes.get(2) != 0 || computeBytes.get(3) != 0)
					throw "GPU compute buffer readback returned the wrong value";
				computeReadback.dispose();
			}
			computeBuffer.dispose();
			computePipeline.dispose();
			computeShader.dispose();
		}
	}

	static function pumpEvents(runtime:Runtime, seconds:Float):Void {
		var deadline = Sys.monotonicTime() + seconds;
		while (Sys.monotonicTime() < deadline) {
			if (!runtime.events.poll())
				runtime.events.wait(0.01);
		}
	}

	static function verifyFrameCallbacks(runtime:Runtime, surface:Surface, renderer:Renderer) {
		var staleCalls = 0;
		var calls = 0;
		var lastTime = 0.0;
		var timing:haxeon.platform.SurfaceFrameTiming = null;
		var first = surface.onFrameTick(function(_) {
			staleCalls++;
		});
		var second = surface.onFrameTick(function(frame) {
			if (frame.timeSeconds < lastTime || frame.width <= 0 || frame.height <= 0)
				throw "Invalid frame callback payload";
			lastTime = frame.timeSeconds;
			timing = surface.captureFrameTiming(frame.timeSeconds);
			renderer.withFrame(function() {});
			timing.markSubmitted();
			calls++;
		});
		pumpEvents(runtime, 0.25);
		if (!first.isDisposed() || staleCalls != 0 || calls < 2 || lastTime <= 0.0)
			throw "Continuous GPU frame callback did not replace its predecessor";
		if (timing == null || timing.callbackSeconds != lastTime || (timing.submittedSeconds ?? 0.0) < lastTime)
			throw "Frame timing did not record callback and submission in the same clock domain";
		timing.presentationSeconds();

		surface.setFrameMode(SurfaceFrameMode.OnDemand);
		pumpEvents(runtime, 0.1);
		var idleCalls = calls;
		pumpEvents(runtime, 0.1);
		if (calls != idleCalls)
			throw "On-demand frame callback kept running without a request";
		surface.requestFrame();
		pumpEvents(runtime, 0.25);
		if (calls != idleCalls + 1)
			throw "GPU frame request did not deliver one frame";

		second.dispose();
		surface.requestFrame();
		pumpEvents(runtime, 0.1);
		if (!second.isDisposed() || calls != idleCalls + 1)
			throw "Disposed GPU frame subscription still received callbacks";
		return surface.onFrameTick(function(_) {});
	}

	static function main():Int {
		verifyGeneratedEnumMembers();
		verifyStructuredErrors();
		var runtime = Runtime.start();
		var windowOptions = new NativeWindowOptions();
		windowOptions.set_width(800);
		windowOptions.set_height(600);
		windowOptions.set_title("Haxeon: GPU over NativeKit");
		windowOptions.set_flags(WindowFlags.Resizable);
		windowOptions.set_owner(WindowHandle.invalid());
		windowOptions.set_kind(WindowKind.Normal);
		var window:Window = runtime.createWindowNative(windowOptions);
		var surface = window.createSurface(GpuSurfaceOptions.forGpu(800, 600));
		var renderer:Null<Renderer> = null;
		var buffer:Null<Buffer> = null;
		var indexBuffer:Null<Buffer> = null;
		var shader:Null<Shader> = null;
		var pipeline:Null<Pipeline> = null;
		var image:Null<Image> = null;
		var sampler:Null<Sampler> = null;
		var ready = false;
		var running = true;
		var frames = 0;
		var retainedImage:Null<GraphicsImageRef> = null;
		var immediateMs = 0.0;
		var batchedMs = 0.0;
		var commandBuffer:Null<CommandBuffer> = null;
		var surfaceReady = false;
		var queuedFrame:Null<haxe.Int64> = null;
		var queuedResult:Null<Result> = null;
		var closeSubscription = window.onClose(function() running = false);
		var readySubscription = surface.onReady(function() surfaceReady = true);
		var completeSubscription = surface.onFrameComplete(function(token, result) {
			if (queuedFrame != null && token == queuedFrame)
				queuedResult = result;
		});

		while (running) {
			runtime.events.poll();
			if (!ready && surfaceReady) {
				renderer = Renderer.create(surface);
				scoped var reflectedShader = Fixture.create(renderer, FixtureVariant.Default);
				scoped var previewShader = Fixture.create(renderer, FixtureVariant.Preview);
				if (Fixture.vsParams.slot != 0 || Fixture.vsParams.size != 48)
					throw "Reflected uniform block slot or size changed";
				commandBuffer = renderer.commandBuffer(64);

				buffer = createVertexBuffer(renderer);
				indexBuffer = createIndexBuffer(renderer);
				image = createCheckerboard(renderer);
				sampler = Sampler.create(renderer, Filter.Nearest, Filter.Nearest,
					Wrap.Repeat, Wrap.Repeat);
				shader = createShader(renderer);
				pipeline = createPipeline(renderer, shader);
				var peerRenderer = Renderer.create(surface);
				var wrongShaderRendererRejected = false;
				try Pipeline.begin(peerRenderer, shader,
					vertexLayout) catch (_:Dynamic) wrongShaderRendererRejected = true;
				if (!wrongShaderRendererRejected)
					throw "GPU pipeline accepted a shader from another renderer";
				peerRenderer.beginFrame();
				var wrongCommandRendererRejected = false;
				try peerRenderer.submit(commandBuffer) catch (_:Dynamic) wrongCommandRendererRejected = true;
				if (!wrongCommandRendererRejected)
					throw "GPU renderer accepted a command buffer from another renderer";
				peerRenderer.endFrame();
				peerRenderer.dispose();

				var colorDesc = new ImageDesc(32, 32, ImageFormat.Rgba8,
					ImageUsage.Sampled | ImageUsage.RenderTarget);
				var targetColor = Image.create(renderer, colorDesc);
				var depthDesc = new ImageDesc(32, 32, ImageFormat.Depth24Stencil8,
					ImageUsage.DepthStencil);
				var targetDepth = Image.create(renderer, depthDesc);
				var pass = new RenderPassDesc();
				var colorAction = new AttachmentAction(LoadAction.Clear, StoreAction.Store);
				colorAction.clearAlpha = 1.0;
				var depthAction = new AttachmentAction(LoadAction.Clear, StoreAction.Store);
				pass.color(targetColor, colorAction).depth(targetDepth, depthAction);
				renderer.beginPassFrame();
				renderer.beginRenderPass(pass);
				renderer.viewport(0, 0, 32, 32);
				renderer.scissor(true, 0, 0, 32, 32);
				var resourceCreationRejected = false;
				try Sampler.create(renderer) catch (_:Dynamic) resourceCreationRejected = true;
				if (!resourceCreationRejected)
					throw "GPU resource creation succeeded during an active pass";
				applyFrameBindings(pipeline, buffer, indexBuffer, image, sampler);
				renderer.uniforms(16).writeFloat(0, 0).writeFloat(4, 0).apply(0);
				renderer.draw(0, 6);
				renderer.scissor(false);
				renderer.endPass();
				renderer.endFrame();
				retainedImage = targetColor.graphicsImage();
				if (retainedImage.width != 32 || retainedImage.height != 32
					|| (retainedImage.api != GraphicsApi.Opengl
					&& retainedImage.api != GraphicsApi.OpenglEs
					&& retainedImage.api != GraphicsApi.D3d11
					&& retainedImage.api != GraphicsApi.Metal))
					throw "offscreen target image metadata mismatch";
				var copyDesc = new ImageDesc(32, 32, ImageFormat.Rgba8,
					ImageUsage.Sampled | ImageUsage.RenderTarget);
				var copyDestination = Image.create(renderer, copyDesc);
				renderer.beginPassFrame();
				renderer.beginCopyPass();
				renderer.copyImage(targetColor, copyDestination, 32, 32);
				renderer.endPass();
				renderer.endFrame();
				copyDestination.dispose();
				var transferSource = Buffer.create(renderer, new BufferDesc(4, BufferUsage.Transfer));
				var transferDestination = Buffer.create(renderer, new BufferDesc(4, BufferUsage.Transfer));
				renderer.beginPassFrame();
				renderer.beginCopyPass();
				renderer.copyBuffer(transferSource, transferDestination, 4);
				renderer.endPass();
				renderer.endFrame();
				var transferImage = Image.create(renderer, new ImageDesc(1, 1, ImageFormat.R32Uint,
					ImageUsage.Sampled | ImageUsage.RenderTarget));
				renderer.beginPassFrame();
				renderer.beginCopyPass();
				renderer.bufferToImage(transferDestination, transferImage, 1, 1);
				renderer.imageToBuffer(transferImage, transferDestination, 1, 1);
				renderer.endPass();
				renderer.endFrame();
				transferImage.dispose();
				transferSource.dispose();
				transferDestination.dispose();
				encodeBatched(commandBuffer, pipeline, buffer, indexBuffer, image, sampler);
				var renderBatch = renderer.batch().renderPass(pass).seal();
				var renderFrame = surface.acquireFrame();
				renderBatch.submit(renderFrame);
				renderFrame.present();
				renderBatch.dispose();
				var sealedBatch = renderer.batch().windowPass(800, 600).commands(commandBuffer).seal();
				var batchMutationRejected = false;
				try sealedBatch.copyPass() catch (_:Dynamic) batchMutationRejected = true;
				if (!batchMutationRejected)
					throw "GPU sealed batch accepted a new pass";
				var windowFrame = surface.acquireFrame();
				sealedBatch.submit(windowFrame);
				windowFrame.present();
				exerciseOptionalFeatures(renderer);
				var queuedWindowFrame = surface.acquireFrame();
				queuedFrame = queuedWindowFrame.token();
				var windowStep = sealedBatch.frameStep();
				defer windowStep.dispose();
				queuedWindowFrame.submit([windowStep]);
				sealedBatch.dispose();
				var deadline = Sys.monotonicTime() + 5.0;
				while (queuedResult == null && Sys.monotonicTime() < deadline) {
					if (!runtime.events.poll())
						runtime.events.wait(0.01);
				}
				if (queuedResult != Result.Ok)
					throw "Queued GPU window frame failed: " + Std.string(queuedResult);
				targetColor.dispose();
				targetDepth.dispose();
				ready = true;
			}

			if (ready && running) {
				renderer.beginFrame();
				if (frames == 0 && NativeKitGpu.nkgpu_submit_commands(renderer.nativeHandle(), Bytes.alloc(4), 4)
					!= GpuStatus.ErrorInvalidArgument)
					throw "truncated command stream was accepted";
				var started = Date.now().getTime();
				if (frames < 12) {
					applyFrameBindings(pipeline, buffer, indexBuffer, image, sampler);
					drawImmediate(renderer);
					immediateMs += Date.now().getTime() - started;
				} else {
					encodeBatched(commandBuffer, pipeline, buffer, indexBuffer, image, sampler);
					renderer.submit(commandBuffer);
					batchedMs += Date.now().getTime() - started;
				}
				renderer.endFrame();
				frames += 1;
				if (frames >= 24)
					running = false;
			}
		}

		renderer.beginFrame();
		renderer.abortFrame();
		renderer.abortFrame();
		var originalError = "draw failed";
		var frameError:Dynamic = null;
		try renderer.withFrame(function() {
			throw originalError;
		})
			catch (error:Dynamic) frameError = error;
		if (frameError != originalError)
			throw "Frame scope did not preserve the draw error";
		renderer.withFrame(function() {});
		var frameSubscription = verifyFrameCallbacks(runtime, surface, renderer);

		var stalePipeline = pipeline.nativeHandle();
		sampler.dispose();
		sampler.dispose();
		image.dispose();
		pipeline.dispose();
		if (NativeKitGpu.nkgpu_pipeline_destroy(renderer.nativeHandle(), stalePipeline) != GpuStatus.ErrorInvalidHandle)
			throw "stale pipeline handle was accepted";
		shader.dispose();
		indexBuffer.dispose();
		renderer.dispose();
		if (!buffer.isDisposed())
			throw "GPU renderer did not dispose its remaining resources";
		buffer.dispose();
		buffer.dispose();
		var blockedRuntimeShutdown = false;
		try runtime.dispose() catch (_:Dynamic) blockedRuntimeShutdown = true;
		if (!blockedRuntimeShutdown || runtime.isDisposed())
			throw "runtime shut down with a retained graphics image";
		retainedImage.dispose();
		var resizeCalls = 0;
		var resizeSubscription = surface.onResize(function(_, _, _, _) resizeCalls++);
		var resize = PlatformEvent.SurfaceResize(new Handle(surface.nativeHandle().rawValue()), 800, 600, 800, 600);
		runtime.events.dispatch(resize);
		surface.dispose();
		runtime.events.dispatch(resize);
		if (!frameSubscription.isDisposed() || !readySubscription.isDisposed() || !completeSubscription.isDisposed()
			|| !resizeSubscription.isDisposed() || resizeCalls != 1)
			throw "Surface disposal did not detach its subscriptions";
		var keyCalls = 0;
		var keySubscription = window.onKey(function(_, _, _, _) {
			keyCalls++;
			return true;
		});
		var windowKey = PlatformEvent.Key(new Handle(window.nativeHandle().rawValue()), Key.R, 0,
			InputAction.Press, Modifiers.empty());
		runtime.events.dispatch(PlatformEvent.Key(new Handle(0), Key.R, 0, InputAction.Press, Modifiers.empty()));
		runtime.events.dispatch(windowKey);
		window.dispose();
		runtime.events.dispatch(windowKey);
		if (!keySubscription.isDisposed() || !closeSubscription.isDisposed() || keyCalls != 1)
			throw "Window key routing persisted after disposal";
		{
			scoped var retryWindow = runtime.createWindowNative(windowOptions);
			var retrySurface = retryWindow.createSurface(GpuSurfaceOptions.forGpu(800, 600));
			verifyFrameCompletionRecovery(runtime, retrySurface, new TriangleLoopApp(retrySurface));
		}
		runtime.dispose();

		var recorded = 0;
		var app:Null<TriangleLoopApp> = null;
		Runtime.launch(function(active) {
			var loopWindow = active.createWindowNative(windowOptions);
			var loopSurface = loopWindow.createSurface(GpuSurfaceOptions.forGpu(800, 600));
			var launched = new TriangleLoopApp(loopSurface);
			active.drive(loopSurface, new FrameRecorder(function(timing) {
				if (timing.submittedSeconds == null || timing.submittedSeconds < timing.callbackSeconds)
					throw "Frame recorder returned out-of-order timestamps";
				recorded++;
			}));
			app = launched;
			return launched;
		});
		if (app == null)
			throw "The launch factory did not run";
		app.verify();
		if (recorded != 1)
			throw "Frame recorder must report the submitted frame and skip the canceled frame";

		Sys.println("draws_per_frame=400");
		Sys.println("immediate_cpu_ms_per_frame=" + immediateMs / 12.0);
		Sys.println("batched_encode_and_submit_ms_per_frame=" + batchedMs / 12.0);
		return frames == 24 && immediateMs > batchedMs ? 42 : 4;
	}
}

private class TriangleLoopApp implements App {
	final surface:Surface;
	var renderer:Renderer;
	var batch:haxeon.gpu.Batch;
	var token:haxe.Int64;
	var frames = 0;
	var afterFrames = 0;
	var completions = 0;
	var disposed = false;

	public function new(surface:Surface) {
		this.surface = surface;
		surface.onFrameComplete(function(completed, result) {
			if (completed == token && result == Result.Ok)
				completions++;
		});
	}

	public function ready():Void
		renderer = Renderer.create(surface);

	public function frame(tick:FrameTick, frame:SurfaceFrame):Void {
		if (renderer == null || tick.timeSeconds <= 0.0)
			throw "The app drew before its surface was ready";
		frames++;
		if (frames == 1) {
			var rejected = false;
			try frame.submit([]) catch (error:haxeon.platform.NativeKitError) {
				rejected = error.result == Result.ErrorInvalidArgument;
			}
			if (!rejected || frame.isFinished())
				throw "NativeKit did not reject an empty submission and leave the frame open";
			return;
		}
		if (afterFrames != 1)
			throw "The loop did not run post-frame work before drawing again";
		batch = renderer.batch().windowPass(tick.width, tick.height).seal();
		var step = batch.frameStep();
		defer step.dispose();
		token = frame.token();
		frame.submit([step]);
	}

	public function afterFrame():Void
		afterFrames++;

	public function shouldQuit():Bool
		return frames == 2;

	public function dispose():Void {
		disposed = true;
		defer if (renderer != null) renderer.dispose();
		if (batch != null) batch.dispose();
	}

	public function verify():Void {
		if (frames != 2 || afterFrames != 2 || completions != 1 || !disposed)
			throw "The loop quit without completing the submitted frame and disposing the app";
	}
}
