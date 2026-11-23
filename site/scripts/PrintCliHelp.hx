import tools.CliHelp;

class PrintCliHelp {
	static function main() {
		final overview = CliHelp.overview();
		Sys.println("## Command help");
		Sys.println("\n```text\n" + overview + "\n```");
		final commandLine = ~/^  (\S+)/;
		for (line in overview.split("\n")) {
			if (!commandLine.match(line))
				continue;
			final name = commandLine.matched(1);
			final help = CliHelp.command(name);
			if (help == null)
				throw 'No help for $name';
			Sys.println('\n### $name\n\n```text\n$help\n```');
		}
	}
}
