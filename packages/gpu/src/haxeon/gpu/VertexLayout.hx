package haxeon.gpu;

import haxeon.gpu.Enums.VertexFormat;

/** One attribute of a vertex: where it sits and its format. */
typedef VertexAttribute = {
	final slot:Int;
	final bufferIndex:Int;
	final offset:Int;
	final format:VertexFormat;
}

/** How a vertex buffer's records are laid out, as the shader build generates for a shader's inputs. */
class VertexLayout {
	/** No vertex buffers: the shader reads its inputs from storage buffers or builtins. */
	public static final none = new VertexLayout(0, []);

	/** The bytes from one vertex to the next. */
	public final stride:Int;
	final attributes:Array<VertexAttribute>;

	/** A layout of `stride`-byte vertices with `attributes`. */
	public function new(stride:Int, attributes:Array<VertexAttribute>) {
		this.stride = stride;
		this.attributes = attributes;
	}

	@:allow(haxeon.gpu.Pipeline)
	function apply(builder:Pipeline.PipelineBuilder):Pipeline.PipelineBuilder {
		for (attribute in attributes)
			builder.attribute(attribute.slot, attribute.bufferIndex, attribute.offset, attribute.format);
		return builder;
	}
}
