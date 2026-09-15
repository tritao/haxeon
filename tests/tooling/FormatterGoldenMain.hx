import compiler.formatter.FormatConfig.FormatConfigTools;
import compiler.formatter.Formatter;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;

class FormatterGoldenMain {
	static function main():Void {
		var root = "tests/formatter", count = 0;
		for (directory in FileSystem.readDirectory(root)) {
			var directoryPath = Path.join([root, directory]);
			if (!FileSystem.isDirectory(directoryPath))
				continue;
			var inputPath = Path.join([directoryPath, "input.txt"]),
				expectedPath = Path.join([directoryPath, "expected.txt"]);
			if (!FileSystem.exists(inputPath) || !FileSystem.exists(expectedPath))
				throw 'Golden formatter case "$directory" needs input.txt and expected.txt';
			var config = FormatConfigTools.defaults(2, true);
			config.lineWidth = switch directory {
				case "arguments": 60;
				case "binary": 40;
				case "literals": 50;
				default: 120;
			};
			var input = File.getContent(inputPath),
				expected = File.getContent(expectedPath),
				formatted = Formatter.format(input, config);
			if (formatted == null)
				throw 'Golden formatter case "$directory" was rejected by the parser';
			if (formatted != expected)
				throw 'Golden formatter case "$directory" differs from expected output';
			if (Formatter.format(formatted, config) != expected)
				throw 'Golden formatter case "$directory" is not idempotent';
			count++;
		}
		if (count == 0)
			throw "No formatter golden cases found";
		Sys.println('PASS: $count formatter golden cases');
	}
}
