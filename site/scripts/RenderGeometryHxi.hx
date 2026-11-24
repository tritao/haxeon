import compiler.ffi.HxiParser;
import compiler.ffi.HxiWriter;
import sys.io.File;

class RenderGeometryHxi {
	static function main():Void {
		var path = Sys.args()[0];
		Sys.print(HxiWriter.write(HxiParser.parse(path, File.getContent(path)), null, null, 38));
	}
}
