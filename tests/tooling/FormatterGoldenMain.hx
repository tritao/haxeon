import compiler.formatter.FormatConfig.FormatConfigTools;
import compiler.formatter.Formatter;
import compiler.formatter.ProjectFormat;
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
			// A `stable.hx` case is already formatted in the default style (tabs, 120 columns): formatting it must change nothing.
			var stablePath = Path.join([directoryPath, "stable.hx"]);
			if (FileSystem.exists(stablePath)) {
				var source = File.getContent(stablePath), formatted = Formatter.format(source, ProjectFormat.standard());
				if (formatted != source)
					throw 'Stable formatter case "$directory" changed:\n$formatted';
				count++;
				continue;
			}
			if (!FileSystem.exists(inputPath) || !FileSystem.exists(expectedPath))
				throw 'Golden formatter case "$directory" needs input.txt and expected.txt';
			var config = FormatConfigTools.make(2, true);
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
