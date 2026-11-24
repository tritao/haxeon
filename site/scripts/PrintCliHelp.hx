import haxe.Json;
import tools.CliHelp;

class PrintCliHelp {
	static function main() {
		final groups = CliHelp.commandGroups().map(group -> {
			final commands = group.commands.map(name -> {
				final help = CliHelp.command(name);
				if (help == null)
					throw 'No help for $name';
				return {name: name, help: help};
			});
			return {title: group.title, commands: commands};
		});
		Sys.println(Json.stringify({overview: CliHelp.overview(), groups: groups}));
	}
}
