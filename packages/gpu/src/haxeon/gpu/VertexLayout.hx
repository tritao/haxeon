package haxeon.gpu;

import haxeon.gpu.Enums.VertexFormat;

typedef VertexAttribute = {
	final slot:Int;
	final bufferIndex:Int;
	final offset:Int;
	final format:VertexFormat;
}

class VertexLayout {
	/** No vertex buffers: the shader reads its inputs from storage buffers or builtins. */
	public static final none = new VertexLayout(0, []);

	public final stride:Int;
	final attributes:Array<VertexAttribute>;

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
