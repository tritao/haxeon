import compiler.Frontend;
import compiler.hl.HlWriter;
import compiler.ir.HlLower;
import sys.io.File;

class Main {
    static function main():Void {
        var arguments = Sys.args();
        var sourcePath = arguments.length > 0 ? arguments[0] : "tests/programs/add.hx";
        var outputPath = arguments.length > 1 ? arguments[1] : "out/program.hl";
        var ir = Frontend.compile(File.getContent(sourcePath));
        File.saveBytes(outputPath, HlWriter.encode(HlLower.lower(ir)));
        Sys.println('compiled $sourcePath -> $outputPath');
    }
}
