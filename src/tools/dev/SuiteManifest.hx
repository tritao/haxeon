package tools.dev;

import compiler.core.InternalError;
import sys.io.File;

/** One line of tests/suites.txt. */
typedef Suite = {
	final name:String;
	final groups:Array<String>;

	/** Suites of one lane run one after another, in the background, from where the first of them is listed. */
	final lane:Null<String>;

	/** Consecutive suites of one pool run at once; the list waits for the pool. */
	final pool:Null<String>;

	final requires:Array<String>;

	/** Skipped when one of these variables is 1. */
	final unlessEnv:Array<String>;

	final freshNative:Bool;
	final cliLauncher:Bool;

	/** A bash command, run from the repository root; `{jobs}` is the job count. */
	final command:String;

	final line:Int;
}

/** The ordered suite list of tests/suites.txt (its header documents the format) and the selection of a mode. */
class SuiteManifest {
	public static final GROUPS = ["quick", "wave", "ci"];
	public static final MODES = ["quick", "wave", "ci", "full"];
	static final TOOLS = ["wasmtime"];

	public static function parse(path:String):Array<Suite> {
		var suites:Array<Suite> = [], names = new Map<String, Bool>(), number = 0;
		for (raw in File.getContent(path).split("\n")) {
			number++;
			var text = StringTools.trim(raw);
			if (text == "" || StringTools.startsWith(text, "#"))
				continue;
			var separator = text.indexOf(" -- ");
			if (separator < 0)
				throw new InternalError('$path:$number: a suite line needs " -- " before its command');
			var command = StringTools.trim(text.substr(separator + 4)),
				fields = ~/\s+/g.split(StringTools.trim(text.substr(0, separator)));
			if (fields.length < 2 || command == "")
				throw new InternalError('$path:$number: expected <name> <groups> [options] -- <command>');
			var name = fields[0], groups = fields[1].split(",");
			if (!~/^[a-z0-9][a-z0-9-]*$/.match(name))
				throw new InternalError('$path:$number: suite name "$name" must be lowercase letters, digits and dashes');
			if (names.exists(name))
				throw new InternalError('$path:$number: duplicate suite "$name"');
			names.set(name, true);
			for (group in groups)
				if (GROUPS.indexOf(group) < 0)
					throw new InternalError('$path:$number: unknown group "$group" (known: ${GROUPS.join(", ")})');
			var lane:Null<String> = null,
				pool:Null<String> = null,
				requires = [],
				unlessEnv = [],
				freshNative = false,
				cliLauncher = false;
			for (option in fields.slice(2)) {
				var equals = option.indexOf("="),
					key = equals < 0 ? option : option.substr(0, equals),
					value = equals < 0 ? "" : option.substr(equals + 1);
				switch key {
					case "lane" if (value != ""):
						lane = value;
					case "pool" if (value != ""):
						pool = value;
					case "requires" if (TOOLS.indexOf(value) >= 0):
						requires.push(value);
					case "unless-env" if (value != ""):
						unlessEnv.push(value);
					case "fresh-native" if (equals < 0):
						freshNative = true;
					case "cli-launcher" if (equals < 0):
						cliLauncher = true;
					case _:
						throw new InternalError('$path:$number: unknown or malformed option "$option"');
				}
			}
			if (lane != null && pool != null)
				throw new InternalError('$path:$number: a suite is in a lane or a pool, not both');
			suites.push({
				name: name,
				groups: groups,
				lane: lane,
				pool: pool,
				requires: requires,
				unlessEnv: unlessEnv,
				freshNative: freshNative,
				cliLauncher: cliLauncher,
				command: command,
				line: number
			});
		}
		requireContiguous(suites, path, suite -> suite.lane, "lane");
		requireContiguous(suites, path, suite -> suite.pool, "pool");
		return suites;
	}

	/** The suites a mode runs, in list order. */
	public static function select(suites:Array<Suite>, mode:String):Array<Suite> {
		var groups = switch mode {
			case "quick": ["quick"];
			case "wave": ["quick", "wave"];
			case "ci": ["ci"];
			case "full": GROUPS;
			case _: throw new InternalError('Unknown test mode "$mode" (known: ${MODES.join(", ")})');
		};
		return [
			for (suite in suites)
				if (suite.groups.filter(group -> groups.indexOf(group) >= 0).length > 0) suite
		];
	}

	/** A lane or pool listed in two places would run from the first and silently move the rest. */
	static function requireContiguous(suites:Array<Suite>, path:String, key:Suite->Null<String>, what:String):Void {
		var closed = new Map<String, Bool>(), current:Null<String> = null;
		for (suite in suites) {
			var value = key(suite);
			if (value != current) {
				if (current != null)
					closed.set(current, true);
				if (value != null && closed.exists(value))
					throw new InternalError('$path:${suite.line}: the suites of $what "$value" must be listed together');
				current = value;
			}
		}
	}
}
