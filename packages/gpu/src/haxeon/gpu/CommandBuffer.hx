package haxeon.gpu;

import haxeon.platform.BindingError;

import haxeon.gpu.Buffer;
import haxeon.gpu.Image;
import haxeon.gpu.Pipeline;
import haxeon.gpu.Sampler;

import haxeon.gpu.Renderer;

import haxe.io.Bytes;

/**
 * Commands recorded ahead of time and replayed by `Renderer.submit` or a batch, so a frame's drawing can be built once
 * and reused.
 */
class CommandBuffer {
	final renderer:Renderer;
	var bytes:Bytes;
	var length:Int;

	@:allow(haxeon.gpu.Renderer)
	private function new(renderer:Renderer, capacity:Int) {
		if (capacity <= 0)
			throw BindingError.invalidArgument("CommandBuffer.new", "command buffer capacity must be positive");
		this.renderer = renderer;
		bytes = Bytes.alloc(capacity);
		length = 0;
	}

	/** Empties it for recording again. */
	public function reset():Void
		length = 0;

	internal function data():Bytes
		return bytes;

	internal function size():Int
		return length;

	@:allow(haxeon.gpu.Renderer)
	@:allow(haxeon.gpu.Batch)
	function ensureRenderer(owner:Renderer):Void {
		if (renderer != owner)
			throw BindingError.invalidArgument("CommandBuffer.ensureRenderer",
				"GPU command buffer belongs to a different renderer");
	}

	/** Records binding `pipeline`. */
	public function applyPipeline(pipeline:Pipeline):Void {
		ensureRenderer(pipeline.rendererOwner());
		header(1, 12);
		word(pipeline.nativeHandle().rawValue());
	}

	/** Records binding `buffer` as vertex buffer `slot`, from byte `offset`. */
	public function applyVertexBuffer(slot:Int, buffer:Buffer, offset:Int):Void {
		ensureRenderer(buffer.rendererOwner());
		if (slot < 0 || offset < 0)
			throw BindingError.invalidArgument("CommandBuffer.applyVertexBuffer",
				"GPU vertex-buffer slot and offset must be non-negative");
		header(2, 20);
		word(slot);
		word(buffer.nativeHandle().rawValue());
		word(offset);
	}

	/** Records binding `buffer` as the index buffer, from byte `offset`. */
	public function applyIndexBuffer(buffer:Buffer, offset:Int):Void {
		ensureRenderer(buffer.rendererOwner());
		if (offset < 0)
			throw BindingError.invalidArgument("CommandBuffer.applyIndexBuffer",
				"GPU index-buffer offset must be non-negative");
		header(3, 16);
		word(buffer.nativeHandle().rawValue());
		word(offset);
	}

	/** Records binding `image` to texture `slot`. */
	public function applyImage(slot:Int, image:Image):Void {
		ensureRenderer(image.rendererOwner());
		if (slot < 0)
			throw BindingError.invalidArgument("CommandBuffer.applyImage", "GPU image slot must be non-negative");
		header(4, 16);
		word(slot);
		word(image.nativeHandle().rawValue());
	}

	/** Records binding `sampler` to sampler `slot`. */
	public function applySampler(slot:Int, sampler:Sampler):Void {
		ensureRenderer(sampler.rendererOwner());
		if (slot < 0)
			throw BindingError.invalidArgument("CommandBuffer.applySampler", "GPU sampler slot must be non-negative");
		header(5, 16);
		word(slot);
		word(sampler.nativeHandle().rawValue());
	}

	/** Records binding `buffer` to storage buffer `slot`. */
	public function applyStorageBuffer(slot:Int, buffer:Buffer):Void {
		ensureRenderer(buffer.rendererOwner());
		if (slot < 0)
			throw BindingError.invalidArgument("CommandBuffer.applyStorageBuffer",
				"GPU storage-buffer slot must be non-negative");
		header(11, 16);
		word(slot);
		word(buffer.nativeHandle().rawValue());
	}

	/** Records binding `image` to storage image `slot`. */
	public function applyStorageImage(slot:Int, image:Image):Void {
		ensureRenderer(image.rendererOwner());
		if (slot < 0)
			throw BindingError.invalidArgument("CommandBuffer.applyStorageImage",
				"GPU storage-image slot must be non-negative");
		header(12, 16);
		word(slot);
		word(image.nativeHandle().rawValue());
	}

	/** Records setting uniform block `slot` to `data`. */
	public function applyUniforms(slot:Int, data:Bytes):Void {
		if (slot < 0 || data == null)
			throw BindingError.invalidArgument("CommandBuffer.applyUniforms", "GPU uniform slot and data are invalid");
		header(6, 16 + data.length);
		word(slot);
		word(data.length);
		require(data.length);
		for (index in 0...data.length)
			bytes.set(length + index, data.get(index));
		length += data.length;
	}

	/** Records setting uniform block `slot` to two floats. */
	public function applyUniform2f(slot:Int, x:Float, y:Float):Void {
		if (slot < 0)
			throw BindingError.invalidArgument("CommandBuffer.applyUniform2f", "GPU uniform slot must be non-negative");
		header(6, 32);
		word(slot);
		word(16);
		bytes.setFloat(length, x);
		bytes.setFloat(length + 4, y);
		bytes.setInt32(length + 8, 0);
		bytes.setInt32(length + 12, 0);
		length += 16;
	}

	/** Records drawing `elementCount` elements from `baseElement`, `instanceCount` times. */
	public function draw(baseElement:Int, elementCount:Int, instanceCount:Int):Void {
		if (baseElement < 0 || elementCount <= 0 || instanceCount <= 0)
			throw BindingError.invalidArgument("CommandBuffer.draw",
				"GPU draw range and instance count must be positive");
		header(7, 20);
		word(baseElement);
		word(elementCount);
		word(instanceCount);
	}

	/** Records setting or clearing the scissor rectangle, in framebuffer pixels. */
	public function scissor(enabled:Bool, x:Int = 0, y:Int = 0, width:Int = 0,
			height:Int = 0):Void {
		if (enabled && (width <= 0 || height <= 0))
			throw BindingError.invalidArgument("CommandBuffer.scissor",
				"GPU scissor dimensions must be positive when enabled");
		header(8, 28);
		word(enabled ? 1 : 0);
		word(x);
		word(y);
		word(width);
		word(height);
	}

	/** Records setting the viewport, in framebuffer pixels. */
	public function viewport(x:Int, y:Int, width:Int, height:Int):Void {
		if (width <= 0 || height <= 0)
			throw BindingError.invalidArgument("CommandBuffer.viewport", "GPU viewport dimensions must be positive");
		header(10, 24);
		word(x);
		word(y);
		word(width);
		word(height);
	}

	/** Records dispatching `x` by `y` by `z` compute workgroups. */
	public function dispatch(x:Int, y:Int = 1, z:Int = 1):Void {
		if (x <= 0 || y <= 0 || z <= 0)
			throw BindingError.invalidArgument("CommandBuffer.dispatch", "GPU dispatch dimensions must be positive");
		header(13, 20);
		word(x);
		word(y);
		word(z);
	}

	/** Records copying `size` bytes between buffers. */
	public function copyBuffer(source:Buffer, destination:Buffer, size:Int,
			sourceOffset:Int = 0, destinationOffset:Int = 0):Void {
		ensureRenderer(source.rendererOwner());
		ensureRenderer(destination.rendererOwner());
		if (size <= 0 || sourceOffset < 0 || destinationOffset < 0)
			throw BindingError.invalidArgument("CommandBuffer.copyBuffer", "GPU buffer-copy arguments are invalid");
		header(14, 28);
		word(source.nativeHandle().rawValue());
		word(sourceOffset);
		word(destination.nativeHandle().rawValue());
		word(destinationOffset);
		word(size);
	}

	/** Records copying a rectangle between images. */
	public function copyImage(source:Image, destination:Image, width:Int, height:Int,
			sourceX:Int = 0, sourceY:Int = 0, destinationX:Int = 0, destinationY:Int = 0,
			sourceMip:Int = 0, sourceLayer:Int = 0, destinationMip:Int = 0,
			destinationLayer:Int = 0):Void {
		ensureRenderer(source.rendererOwner());
		ensureRenderer(destination.rendererOwner());
		if (width <= 0 || height <= 0 || sourceX < 0 || sourceY < 0 || destinationX < 0 || destinationY < 0
			|| sourceMip < 0 || sourceLayer < 0 || destinationMip < 0 || destinationLayer < 0)
			throw BindingError.invalidArgument("CommandBuffer.copyImage", "GPU image-copy arguments are invalid");
		header(15, 56);
		word(source.nativeHandle().rawValue());
		word(sourceMip);
		word(sourceLayer);
		word(sourceX);
		word(sourceY);
		word(destination.nativeHandle().rawValue());
		word(destinationMip);
		word(destinationLayer);
		word(destinationX);
		word(destinationY);
		word(width);
		word(height);
	}

	/** Records uploading a buffer's rows into an image rectangle. */
	public function copyBufferToImage(source:Buffer, destination:Image, width:Int, height:Int,
			rowPitch:Int = 0, bufferOffset:Int = 0, x:Int = 0, y:Int = 0,
			mipLevel:Int = 0, layer:Int = 0):Void {
		ensureRenderer(source.rendererOwner());
		ensureRenderer(destination.rendererOwner());
		if (width <= 0 || height <= 0 || rowPitch < 0 || bufferOffset < 0 || x < 0 || y < 0 || mipLevel < 0
			|| layer < 0)
			throw BindingError.invalidArgument("CommandBuffer.copyBufferToImage",
				"GPU buffer-to-image arguments are invalid");
		header(16, 48);
		word(source.nativeHandle().rawValue());
		word(bufferOffset);
		word(rowPitch);
		word(destination.nativeHandle().rawValue());
		word(mipLevel);
		word(layer);
		word(x);
		word(y);
		word(width);
		word(height);
	}

	/** Records downloading an image rectangle into a buffer. */
	public function copyImageToBuffer(source:Image, destination:Buffer, width:Int, height:Int,
			rowPitch:Int = 0, bufferOffset:Int = 0, x:Int = 0, y:Int = 0,
			mipLevel:Int = 0, layer:Int = 0):Void {
		ensureRenderer(source.rendererOwner());
		ensureRenderer(destination.rendererOwner());
		if (width <= 0 || height <= 0 || rowPitch < 0 || bufferOffset < 0 || x < 0 || y < 0 || mipLevel < 0
			|| layer < 0)
			throw BindingError.invalidArgument("CommandBuffer.copyImageToBuffer",
				"GPU image-to-buffer arguments are invalid");
		header(17, 48);
		word(destination.nativeHandle().rawValue());
		word(bufferOffset);
		word(rowPitch);
		word(source.nativeHandle().rawValue());
		word(mipLevel);
		word(layer);
		word(x);
		word(y);
		word(width);
		word(height);
	}

	function header(opcode:Int, size:Int):Void {
		require(size);
		word(opcode);
		word(size);
	}

	function word(value:Int):Void {
		bytes.setInt32(length, value);
		length += 4;
	}

	function require(count:Int):Void {
		if (count < 0)
			throw BindingError.invalidArgument("CommandBuffer.require", "negative command size");
		if (length <= bytes.length - count)
			return;
		var capacity = bytes.length;
		while (capacity < length + count)
			capacity *= 2;
		var grown = Bytes.alloc(capacity);
		for (index in 0...length)
			grown.set(index, bytes.get(index));
		bytes = grown;
	}
}
