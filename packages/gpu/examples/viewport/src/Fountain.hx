import haxe.io.Bytes;
import haxeon.gpu.AttachmentAction;
import haxeon.gpu.Batch;
import haxeon.gpu.Buffer;
import haxeon.gpu.BufferDesc;
import haxeon.gpu.CommandBuffer;
import haxeon.gpu.Enums;
import haxeon.gpu.Image;
import haxeon.gpu.ImageDesc;
import haxeon.gpu.Pipeline;
import haxeon.gpu.RenderPassDesc;
import haxeon.gpu.Renderer;
import haxeon.gpu.Shader;
import haxeon.gpu.VertexLayout;

import shaders.Fountain as Shaders;

/** A particle fountain simulated by a compute shader and drawn into an offscreen image. */
class Fountain {
	public static inline var size = 512;
	static inline var count = 8192;
	static inline var groupSize = 64;
	static inline var particleBytes = 16;

	public var gravity = 1.5;
	public var spread = 1.1;
	public var warm = false;
	public final image:Image;

	final renderer:Renderer;
	final step:Pipeline;
	final particles:Buffer;
	final simulate:CommandBuffer;
	final draw:CommandBuffer;
	final points:Pipeline;
	final pass:RenderPassDesc;
	final stepParams = Bytes.alloc(Shaders.stepParams.size);
	final drawParams = Bytes.alloc(Shaders.drawParams.size);
	var time = 0.0;
	var resetPending = false;

	public function new(renderer:Renderer) {
		this.renderer = renderer;
		step = Pipeline.beginCompute(renderer, Shader.create(renderer, Shaders.step)).compute().build();
		points = Pipeline.begin(renderer, Shader.create(renderer, Shaders.draw), VertexLayout.none).build();
		particles = Buffer.create(renderer, new BufferDesc(count * particleBytes, BufferUsage.Storage));
		image = Image.create(renderer, new ImageDesc(size, size, ImageFormat.Rgba8,
			ImageUsage.Sampled | ImageUsage.RenderTarget));
		var depth = Image.create(renderer, new ImageDesc(size, size, ImageFormat.Depth24Stencil8,
			ImageUsage.DepthStencil));
		var clear = new AttachmentAction(LoadAction.Clear, StoreAction.Store);
		clear.clearRed = 0.03;
		clear.clearGreen = 0.04;
		clear.clearBlue = 0.07;
		clear.clearAlpha = 1.0;
		pass = new RenderPassDesc().color(image, clear).depth(depth);
		simulate = renderer.commandBuffer(8);
		draw = renderer.commandBuffer(8);
	}

	public function reset():Void
		resetPending = true;

	/** Moves the particles and draws them into `image`. */
	public function record(deltaSeconds:Float):Batch {
		var dt = Math.min(deltaSeconds, 1.0 / 30.0);
		time += dt;
		stepParams.setFloat(0, dt);
		stepParams.setFloat(4, time);
		stepParams.setFloat(8, gravity);
		stepParams.setFloat(12, spread);
		stepParams.setFloat(16, resetPending ? 1.0 : 0.0);
		resetPending = false;
		drawParams.setFloat(0, warm ? 1.0 : 0.0);
		simulate.reset();
		simulate.applyPipeline(step);
		simulate.applyStorageBuffer(0, particles);
		simulate.applyUniforms(Shaders.stepParams.slot, stepParams);
		simulate.dispatch(Std.int(count / groupSize));
		draw.reset();
		draw.applyPipeline(points);
		draw.applyStorageBuffer(0, particles);
		draw.applyUniforms(Shaders.drawParams.slot, drawParams);
		draw.draw(0, 6, count);
		return renderer.batch().computePass().commands(simulate).renderPass(pass).commands(draw).seal();
	}
}
