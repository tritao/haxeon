import haxe.io.Bytes;
import haxeon.gpu.Batch;
import haxeon.gpu.Buffer;
import haxeon.gpu.CommandBuffer;
import haxeon.gpu.BufferDesc;
import haxeon.gpu.Enums;
import haxeon.gpu.Pipeline;
import haxeon.gpu.Renderer;
import haxeon.gpu.Shader;
import haxeon.platform.Surface;

import Circuit.Position;

class CircuitRenderer {
	static inline var tileSize = 36;
	public static inline var width = Circuit.width * tileSize;
	public static inline var height = Circuit.height * tileSize;
	public static inline var surfaceHeight = height + CircuitHud.height;
	static inline var floatBytes = 4;
	static inline var positionComponents = 2;
	static inline var colorComponents = 3;
	static inline var colorOffset = positionComponents * floatBytes;
	static inline var stride = colorOffset + colorComponents * floatBytes;
	static inline var wallInset = 1;
	static inline var wallHighlightInset = 4;
	static inline var wallHighlightHeight = 3;
	static inline var nodeSize = 6;
	static inline var actorInset = 7;
	static inline var actorCoreInset = 11;
	static inline var verticesPerRectangle = 6;
	static inline var backgroundRectangles = 1;
	static inline var maxRectanglesPerTile = 2;
	static inline var actorCount = 2;
	static inline var rectanglesPerActor = 3;

	final vertices = Bytes.alloc((backgroundRectangles + Circuit.width * Circuit.height * maxRectanglesPerTile
		+ actorCount * rectanglesPerActor) * verticesPerRectangle * stride);
	var writeOffset = 0;
	var hudFraction = 0.0;

	final renderer:Renderer;
	final commands:CommandBuffer;
	final pipeline:Pipeline;
	final buffer:Buffer;

	public function new(surface:Surface) {
		renderer = Renderer.create(surface);
		commands = renderer.commandBuffer(64);
		var shader = Shader.begin(renderer, ShaderLanguage.Glsl,
		#if circuit_run_web
			Embed.text("shaders/maze-web.vert.glsl"),
			Embed.text("shaders/maze-web.frag.glsl")).build();
		#else
			Embed.text("shaders/maze.vert.glsl"),
			Embed.text("shaders/maze.frag.glsl")).build();
		#end
		pipeline = Pipeline.begin(renderer, shader, stride)
			.attribute(0, 0, 0, VertexFormat.Float2)
			.attribute(1, 0, colorOffset, VertexFormat.Float3)
			.build();
		var desc = new BufferDesc(vertices.length, BufferUsage.Vertex);
		desc.dynamicUpdate = true;
		buffer = Buffer.create(renderer, desc);
	}

	public function record(game:Circuit, player:Position, drone:Position, width:Int, height:Int):Batch {
		hudFraction = Math.min(1.0, CircuitHud.height * (width / CircuitRenderer.width) / height);
		prepareVertices(game, player, drone);
		commands.reset();
		commands.applyPipeline(pipeline);
		commands.applyVertexBuffer(0, buffer, 0);
		commands.draw(0, Std.int(writeOffset / stride), 1);
		return renderer.batch().windowPass(width, height).commands(commands).seal();
	}

	function prepareVertices(game:Circuit, player:Position, drone:Position):Void {
		writeOffset = 0;
		var background = switch game.state {
			case Playing: 0x10131e;
			case Finished(Captured): 0x381627;
			case Finished(Cleared): 0x153a32;
		};
		rect(0, 0, width, height, background);
		for (index in 0...(Circuit.width * Circuit.height)) {
			var x = (index % Circuit.width) * tileSize;
			var y = Std.int(index / Circuit.width) * tileSize;
			switch game.tile(index) {
				case Wall:
					insetTile(x, y, wallInset, 0x303b58);
					rect(x + wallHighlightInset, y + wallHighlightInset, tileSize - 2 * wallHighlightInset,
						wallHighlightHeight, 0x536988);
				case Node: tileMarker(x, y, nodeSize, nodeSize, 0x82a3be);
				case Floor:
			}
		}
		actor(player, 0x54edc2, 6, 6);
		actor(drone, 0xff6b90, 18, 4);

		buffer.update(0, vertices);
	}

	function actor(position:Position, color:Int, markerWidth:Int, markerHeight:Int):Void {
		var x = position.x * tileSize;
		var y = position.y * tileSize;
		insetTile(x, y, actorInset, color);
		insetTile(x, y, actorCoreInset, 0x10131e);
		tileMarker(x, y, markerWidth, markerHeight, color);
	}

	function insetTile(x:Float, y:Float, inset:Int, color:Int):Void {
		var size = tileSize - 2 * inset;
		rect(x + inset, y + inset, size, size, color);
	}

	function tileMarker(x:Float, y:Float, width:Int, height:Int, color:Int):Void
		rect(x + (tileSize - width) / 2, y + (tileSize - height) / 2, width, height, color);

	function rect(x:Float, y:Float, w:Int, h:Int, color:Int):Void {
		vertex(x, y, color);
		vertex(x, y + h, color);
		vertex(x + w, y, color);
		vertex(x + w, y, color);
		vertex(x, y + h, color);
		vertex(x + w, y + h, color);
	}

	function vertex(x:Float, y:Float, color:Int):Void {
		vertices.setFloat(writeOffset, 2.0 * x / width - 1.0);
		vertices.setFloat(writeOffset + floatBytes, 1.0 - 2.0 * (hudFraction + y / height * (1.0 - hudFraction)));
		vertices.setFloat(writeOffset + colorOffset, ((color >> 16) & 255) / 255.0);
		vertices.setFloat(writeOffset + colorOffset + floatBytes, ((color >> 8) & 255) / 255.0);
		vertices.setFloat(writeOffset + colorOffset + 2 * floatBytes, (color & 255) / 255.0);
		writeOffset += stride;
	}
}
