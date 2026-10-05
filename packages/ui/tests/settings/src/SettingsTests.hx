import haxeon.ui.Size;

import haxeon.ui.core.Command;
import haxeon.ui.core.CommandContext;
import haxeon.ui.core.CommandRegistry;
import haxeon.ui.core.Shortcut;
import haxeon.ui.core.UiKey;
import haxeon.ui.core.UiModifier;
import haxeon.ui.properties.PropertyBinding;
import haxeon.ui.properties.PropertyEditResult;
import haxeon.ui.properties.PropertyOption;
import haxeon.ui.properties.PropertyType;
import haxeon.ui.properties.PropertyValue;
import haxeon.ui.properties.PropertyValueTools;
import haxeon.ui.settings.SettingDefinition;
import haxeon.ui.settings.SettingOptions;
import haxeon.ui.settings.SettingsCatalog;
import haxeon.ui.settings.ShortcutBindings;
import haxeon.ui.settings.SettingsRegistry;
import haxeon.ui.settings.SettingsStore;
import haxeon.ui.widgets.properties.PropertyInspector;
import haxeon.ui.widgets.settings.SettingsPanel;
import haxeon.ui.widgets.settings.ShortcutsPanel;
import sys.FileSystem;
import sys.io.File;

/** Settings core: definitions, defaults, validation, change events and saving. */
class SettingsTests {
	static final DIRECTORY = "build/settings-test";

	public static function main():Int {
		try {
			definitions();
			registry();
			values();
			listeners();
			persistence();
			damagedFiles();
			catalog();
			editing();
			panel();
			shortcutNames();
			customShortcuts();
			shortcutPersistence();
			shortcutsPanel();
			Sys.println("Settings tests passed");
			return 0;
		} catch (error:Dynamic) {
			Sys.println('Settings tests failed: $error');
			return 1;
		}
	}

	static function check(condition:Bool, message:String):Void
		if (!condition)
			throw message;

	static function throws(work:Void->Void, message:String):Void {
		var thrown = false;
		try {
			work();
		} catch (_:Dynamic) {
			thrown = true;
		}
		check(thrown, message);
	}

	static function range(minimum:Float, maximum:Float):SettingOptions {
		var options = new SettingOptions();
		options.minimum = minimum;
		options.maximum = maximum;
		return options;
	}

	static function choices(keys:Array<String>):SettingOptions {
		var options = new SettingOptions();
		options.options = [for (key in keys) new PropertyOption(key, SettingDefinition.labelFor(key))];
		return options;
	}

	/** The editor's sample schema, shared by the value and file tests. */
	static function sampleRegistry():SettingsRegistry {
		var result = new SettingsRegistry();
		result.define("interface/editor/fonts/main_font_size", PropertyType.Int, PropertyValue.Int(14), range(8, 48));
		result.define("interface/editor/appearance/custom_display_scale", PropertyType.Float, PropertyValue.Float(1.0),
			range(0.5, 4.0));
		result.define("interface/editor/appearance/expand_to_title", PropertyType.Bool, PropertyValue.Bool(true));
		result.define("interface/editor/docks/dock_tab_style", PropertyType.Enum, PropertyValue.Enum("text_and_icon"),
			choices(["text_only", "icon_only", "text_and_icon"]));
		result.define("filesystem/directories/default_project_path", PropertyType.Text, PropertyValue.Text(""));
		return result;
	}

	static function definitions():Void {
		var size = new SettingDefinition("interface/editor/fonts/main_font_size", PropertyType.Int, PropertyValue.Int(14));
		check(size.label == "Main Font Size", "labels come from the last path segment");
		check(SettingDefinition.labelFor("show_at_startup") == "Show at Startup", "small words stay lowercase");
		check(SettingDefinition.labelFor("at_startup") == "At Startup", "except the first");
		check(SettingDefinition.labelFor("3d") == "3D" && SettingDefinition.labelFor("tls_ui_scale") == "TLS UI Scale",
			"acronyms are capitalized");
		check(size.segments.length == 4 && size.segments[1] == "editor", "paths split into segments");
		var named = new SettingOptions();
		named.label = "TLS Certificates";
		check(new SettingDefinition("network/tls/certificates", PropertyType.Text, PropertyValue.Text(""), named).label
			== "TLS Certificates", "an explicit label wins");

		throws(() -> new SettingDefinition("Interface/Editor", PropertyType.Bool, PropertyValue.Bool(false)),
			"paths are lowercase");
		throws(() -> new SettingDefinition("interface//editor", PropertyType.Bool, PropertyValue.Bool(false)),
			"paths have no empty segments");
		throws(() -> new SettingDefinition("a/b", PropertyType.Int, PropertyValue.Bool(false)),
			"the default must have the setting's type");
		throws(() -> new SettingDefinition("a/b", PropertyType.Int, PropertyValue.Int(50), range(0, 10)),
			"the default must be in range");
		throws(() -> new SettingDefinition("a/b", PropertyType.Enum, PropertyValue.Enum("x")),
			"enum settings need choices");
		throws(() -> new SettingDefinition("a/b", PropertyType.Enum, PropertyValue.Enum("z"), choices(["x", "y"])),
			"an enum default must be one of the choices");
		throws(() -> new SettingDefinition("a/b", PropertyType.Custom("color"), PropertyValue.Custom("color", 0)),
			"custom types are not settings");

		var scale = new SettingDefinition("a/scale", PropertyType.Float, PropertyValue.Int(1));
		check(PropertyValueTools.same(scale.defaultValue, PropertyValue.Float(1.0)), "an Int default of a Float setting becomes a Float");
		check(scale.validate(PropertyValue.Float(Math.NaN)) != null, "NaN is refused");
	}

	static function registry():Void {
		var registry = new SettingsRegistry();
		var first = registry.define("interface/editor/fonts/main_font_size", PropertyType.Int, PropertyValue.Int(14));
		var again = registry.define("interface/editor/fonts/main_font_size", PropertyType.Int, PropertyValue.Int(14));
		check(first == again, "an identical redefinition returns the first definition");
		throws(() -> registry.define("interface/editor/fonts/main_font_size", PropertyType.Float, PropertyValue.Float(14)),
			"a redefinition with another type is refused");
		throws(() -> registry.define("interface/editor/fonts/main_font_size", PropertyType.Int, PropertyValue.Int(12)),
			"a redefinition with another default is refused");
		throws(() -> registry.define("interface/editor/fonts", PropertyType.Int, PropertyValue.Int(1)),
			"a setting cannot sit on another setting's group");
		registry.define("interface/editor/fonts_extra/size", PropertyType.Int, PropertyValue.Int(1));
		registry.define("interface/inspector/max_array_items", PropertyType.Int, PropertyValue.Int(10));
		check(registry.under("interface/editor").length == 2, "under() matches whole segments");
		check(registry.under("interface/editor/fonts").length == 1, "fonts does not match fonts_extra");
		check(registry.under("").length == 3 && registry.all()[2].path == "interface/inspector/max_array_items",
			"everything, in definition order");
	}

	static function values():Void {
		var store = new SettingsStore(sampleRegistry());
		check(store.getInt("interface/editor/fonts/main_font_size") == 14, "values start at their defaults");
		check(store.isDefault("interface/editor/fonts/main_font_size"), "untouched settings are at their default");

		check(store.set("interface/editor/fonts/main_font_size", PropertyValue.Int(18)) == null, "a valid value is stored");
		check(store.getInt("interface/editor/fonts/main_font_size") == 18, "the new value is read back");
		check(!store.isDefault("interface/editor/fonts/main_font_size"), "a changed setting is no longer at its default");

		check(store.set("interface/editor/fonts/main_font_size", PropertyValue.Int(100)) != null, "out of range is refused");
		check(store.set("interface/editor/fonts/main_font_size", PropertyValue.Text("big")) != null, "a wrong type is refused");
		check(store.getInt("interface/editor/fonts/main_font_size") == 18, "a refused value leaves the setting alone");

		check(store.set("interface/editor/docks/dock_tab_style", PropertyValue.Enum("sideways")) != null,
			"an unknown choice is refused");
		store.set("interface/editor/docks/dock_tab_style", PropertyValue.Enum("icon_only"));
		check(store.getString("interface/editor/docks/dock_tab_style") == "icon_only", "enum values read back as their key");

		store.set("interface/editor/appearance/custom_display_scale", PropertyValue.Int(2));
		check(store.getFloat("interface/editor/appearance/custom_display_scale") == 2.0, "an Int given to a Float setting is stored as a Float");

		store.set("interface/editor/fonts/main_font_size", PropertyValue.Int(14));
		check(store.isDefault("interface/editor/fonts/main_font_size"), "setting the default value clears the override");

		store.reset("interface/editor/docks/dock_tab_style");
		check(store.getString("interface/editor/docks/dock_tab_style") == "text_and_icon", "reset restores the default");

		store.set("interface/editor/appearance/expand_to_title", PropertyValue.Bool(false));
		store.set("filesystem/directories/default_project_path", PropertyValue.Text("/work"));
		store.resetUnder("interface");
		check(store.getBool("interface/editor/appearance/expand_to_title")
			&& store.getFloat("interface/editor/appearance/custom_display_scale") == 1.0, "resetUnder resets the group");
		check(store.getString("filesystem/directories/default_project_path") == "/work", "and nothing outside it");

		throws(() -> store.get("interface/editor/nonexistent"), "reading an undefined setting is a programming error");
		throws(() -> store.getBool("interface/editor/fonts/main_font_size"), "a typed getter checks the type");
	}

	static function listeners():Void {
		var store = new SettingsStore(sampleRegistry());
		var heard:Array<String> = [];
		var everything = 0;
		var stop = store.onChanged("interface/editor/fonts", path -> heard.push(path));
		store.onChanged("", _ -> everything++);
		var before = store.revision;

		store.set("interface/editor/fonts/main_font_size", PropertyValue.Int(20));
		store.set("interface/editor/fonts/main_font_size", PropertyValue.Int(20));
		store.set("interface/editor/appearance/expand_to_title", PropertyValue.Bool(false));
		store.set("interface/editor/fonts/main_font_size", PropertyValue.Int(99));
		check(heard.length == 1 && heard[0] == "interface/editor/fonts/main_font_size",
			"a listener hears real changes under its prefix only");
		check(everything == 2 && store.revision == before + 2, "an empty prefix hears every change; revision counts them");

		store.reset("interface/editor/appearance/custom_display_scale");
		check(everything == 2, "resetting a setting already at its default is not a change");

		stop();
		store.reset("interface/editor/fonts/main_font_size");
		check(heard.length == 1 && everything == 3, "a removed listener hears nothing more");
	}

	static function prepareFile(name:String):String {
		if (!FileSystem.exists("build"))
			FileSystem.createDirectory("build");
		if (!FileSystem.exists(DIRECTORY))
			FileSystem.createDirectory(DIRECTORY);
		var file = DIRECTORY + "/" + name;
		if (FileSystem.exists(file))
			FileSystem.deleteFile(file);
		return file;
	}

	static function persistence():Void {
		var file = prepareFile("settings.json");
		var store = new SettingsStore(sampleRegistry(), file);
		check(!FileSystem.exists(file), "nothing is written until something changes");

		store.set("interface/editor/fonts/main_font_size", PropertyValue.Int(16));
		store.set("interface/editor/appearance/custom_display_scale", PropertyValue.Float(1.25));
		store.set("interface/editor/appearance/expand_to_title", PropertyValue.Bool(false));
		store.set("interface/editor/docks/dock_tab_style", PropertyValue.Enum("text_only"));
		store.set("filesystem/directories/default_project_path", PropertyValue.Text("/home/me/projects"));
		check(store.lastError == null, 'saving works: ${store.lastError}');
		check(!FileSystem.exists(file + ".tmp"), "the temporary file is renamed into place");

		var reopened = new SettingsStore(sampleRegistry(), file);
		check(reopened.getInt("interface/editor/fonts/main_font_size") == 16, "Int survives a restart");
		check(reopened.getFloat("interface/editor/appearance/custom_display_scale") == 1.25, "Float survives a restart");
		check(!reopened.getBool("interface/editor/appearance/expand_to_title"), "Bool survives a restart");
		check(reopened.getString("interface/editor/docks/dock_tab_style") == "text_only", "Enum survives a restart");
		check(reopened.getString("filesystem/directories/default_project_path") == "/home/me/projects",
			"Text survives a restart");

		// Only changed values are saved, so a new default reaches users who never touched the setting.
		reopened.reset("interface/editor/fonts/main_font_size");
		var content = File.getContent(file);
		check(content.indexOf("main_font_size") < 0, "a value at its default is not saved");
		var newDefaults = new SettingsRegistry();
		newDefaults.define("interface/editor/fonts/main_font_size", PropertyType.Int, PropertyValue.Int(15));
		check(new SettingsStore(newDefaults, file).getInt("interface/editor/fonts/main_font_size") == 15,
			"a changed default takes effect for an untouched setting");

		// A value saved by a build that defines more settings is kept.
		File.saveContent(file, '{"version":1,"values":{"plugins/other/flag":true,"interface/editor/fonts/main_font_size":12}}');
		var partial = new SettingsRegistry();
		partial.define("interface/editor/fonts/main_font_size", PropertyType.Int, PropertyValue.Int(14));
		var older = new SettingsStore(partial, file);
		check(older.unknownPaths().join(",") == "interface/editor/fonts/main_font_size,plugins/other/flag",
			"saved values wait until their setting is defined");
		older.set("interface/editor/fonts/main_font_size", PropertyValue.Int(13));
		check(File.getContent(file).indexOf("plugins/other/flag") >= 0, "an undefined setting's saved value is written back");
		check(older.unknownPaths().join(",") == "plugins/other/flag", "a defined setting's value is adopted");
		partial.define("plugins/other/flag", PropertyType.Bool, PropertyValue.Bool(false));
		check(older.getBool("plugins/other/flag"), "a setting defined late picks up its saved value");

		// A batch saves once at the end.
		var batched = prepareFile("batched.json");
		var batch = new SettingsStore(sampleRegistry(), batched);
		batch.batch(function() {
			batch.set("interface/editor/fonts/main_font_size", PropertyValue.Int(20));
			batch.set("interface/editor/fonts/main_font_size", PropertyValue.Int(21));
			check(!FileSystem.exists(batched), "nothing is saved in the middle of a batch");
		});
		check(new SettingsStore(sampleRegistry(), batched).getInt("interface/editor/fonts/main_font_size") == 21,
			"the batch is saved when it ends");

		// Application state rides along in the same file.
		var stateFile = prepareFile("state.json");
		var withState = new SettingsStore(sampleRegistry(), stateFile);
		var heard = 0;
		withState.onChanged("", _ -> heard++);
		withState.setState("recent", ["/a.scene", "/b.scene"]);
		check(heard == 0, "state changes are not setting changes");
		var reloaded = new SettingsStore(sampleRegistry(), stateFile);
		var recent:Array<Dynamic> = reloaded.getState("recent");
		check(recent != null && recent.length == 2 && recent[1] == "/b.scene", "state survives a restart");
		check(reloaded.getState("missing") == null, "missing state is null");
		reloaded.setState("recent", null);
		check(new SettingsStore(sampleRegistry(), stateFile).getState("recent") == null, "null removes state");

		// Saving into a folder that does not exist yet creates it.
		var nested = DIRECTORY + "/nested/deeper/settings.json";
		var deep = new SettingsStore(sampleRegistry(), nested);
		deep.set("interface/editor/appearance/expand_to_title", PropertyValue.Bool(false));
		check(FileSystem.exists(nested), 'missing folders are created: ${deep.lastError}');
	}

	static function damagedFiles():Void {
		var file = prepareFile("damaged.json");
		File.saveContent(file, "{ this is not json");
		var store = new SettingsStore(sampleRegistry(), file);
		check(store.lastError != null, "a damaged file is reported");
		check(store.getInt("interface/editor/fonts/main_font_size") == 14, "a damaged file falls back to defaults");
		store.set("interface/editor/fonts/main_font_size", PropertyValue.Int(10));
		check(new SettingsStore(sampleRegistry(), file).getInt("interface/editor/fonts/main_font_size") == 10,
			"the next save replaces a damaged file");

		File.saveContent(file, '{"version":1,"values":{'
			+ '"interface/editor/fonts/main_font_size":"huge",'
			+ '"interface/editor/appearance/custom_display_scale":99,'
			+ '"interface/editor/docks/dock_tab_style":"sideways",'
			+ '"interface/editor/appearance/expand_to_title":1,'
			+ '"filesystem/directories/default_project_path":"/kept"}}');
		var mixed = new SettingsStore(sampleRegistry(), file);
		check(mixed.getInt("interface/editor/fonts/main_font_size") == 14, "a wrong-type value falls back to the default");
		check(mixed.getFloat("interface/editor/appearance/custom_display_scale") == 1.0, "an out-of-range value falls back");
		check(mixed.getString("interface/editor/docks/dock_tab_style") == "text_and_icon", "an unknown choice falls back");
		check(mixed.getBool("interface/editor/appearance/expand_to_title"), "a number is not a Bool");
		check(mixed.getString("filesystem/directories/default_project_path") == "/kept", "good values beside bad ones survive");

		File.saveContent(file, '[1, 2, 3]');
		var wrongShape = new SettingsStore(sampleRegistry(), file);
		check(wrongShape.lastError != null && wrongShape.isDefault("interface/editor/fonts/main_font_size"),
			"a file of the wrong shape is reported and ignored");
	}


	static function catalogRegistry():SettingsRegistry {
		var registry = sampleRegistry();
		var advanced = new SettingOptions();
		advanced.advanced = true;
		registry.define("interface/editor/fonts/font_hinting", PropertyType.Bool, PropertyValue.Bool(true), advanced);
		registry.define("interface/editor/editor_language", PropertyType.Text, PropertyValue.Text("auto"));
		var hidden = new SettingOptions();
		hidden.internal = true;
		registry.define("interface/editor/window_placement", PropertyType.Text, PropertyValue.Text(""), hidden);
		registry.define("network/debug_port", PropertyType.Int, PropertyValue.Int(6007));
		var restart = new SettingOptions();
		restart.restartRequired = true;
		registry.define("interface/theme/preset", PropertyType.Text, PropertyValue.Text("dark"), restart);
		return registry;
	}

	static function catalog():Void {
		var catalog = new SettingsCatalog(new SettingsStore(catalogRegistry()));
		check(catalog.categories("", false).join(",") == "interface/editor,filesystem/directories,network,interface/theme",
			'categories in definition order: ${catalog.categories("", false).join(",")}');

		var sections = catalog.sections("interface/editor", "", false);
		var labels = [for (section in sections) section.label].join(",");
		check(labels == "Editor,Fonts,Appearance,Docks", 'unsectioned settings come first under the category label: $labels');
		check(sections[0].descriptors.length == 1 && sections[0].descriptors[0].id == "interface/editor/editor_language",
			"internal settings never show");
		check(sections[1].descriptors.length == 1, "advanced settings are hidden by default");
		check(catalog.sections("interface/editor", "", true)[1].descriptors.length == 2, "and shown when asked for");
		check(sections[1].descriptors[0].label == "Main Font Size", "rows use the setting labels");
		check(catalog.sections("interface/theme", "", false)[0].descriptors[0].label == "Preset *",
			"settings that need a restart are marked");

		check(catalog.categories("font", false).join(",") == "interface/editor", "the filter narrows the categories");
		var fonts = catalog.sections("interface/editor", "font", false);
		check(fonts.length == 1 && fonts[0].descriptors.length == 2, "a filter shows matching advanced settings too");
		check(catalog.categories("MAIN font", false).length == 1, "the filter ignores case");
		check(catalog.categories("debug port", false).join(",") == "network", "the filter matches paths with spaces");
		check(catalog.categories("nothing matches this", true).length == 0, "no match, no categories");
		check(catalog.categories("placement", true).length == 0, "the filter never reveals internal settings");

		check(catalog.descriptor(catalogRegistry().get("network/debug_port")) == catalog.descriptor(catalogRegistry().get("network/debug_port")),
			"a setting keeps one descriptor, so its editor keeps its state");
	}

	/** Rows edit the store through the same binding inspectors use, with no document open. */
	static function editing():Void {
		var store = new SettingsStore(sampleRegistry());
		var catalog = new SettingsCatalog(store);
		var size = catalog.descriptor(store.registry.get("interface/editor/fonts/main_font_size"));
		check(!size.recordHistory, "settings stay out of undo history");
		var context = new CommandContext();
		check(context.document == null, "no document is open");
		var binding = new PropertyBinding(size, context);
		check(sameResult(binding.apply(PropertyValue.Int(20)), PropertyEditResult.Applied), "an edit applies without a document");
		check(store.getInt("interface/editor/fonts/main_font_size") == 20, "the edit reaches the store");
		check(sameResult(binding.apply(PropertyValue.Int(20)), PropertyEditResult.Unchanged), "the same value is unchanged");
		check(!sameResult(binding.apply(PropertyValue.Int(500)), PropertyEditResult.Applied), "out of range is rejected");
		check(store.getInt("interface/editor/fonts/main_font_size") == 20, "a rejected edit leaves the store alone");
		store.reset("interface/editor/fonts/main_font_size");
		check(PropertyValueTools.same(binding.read(), PropertyValue.Int(14)), "the row reads what the store holds");
	}

	static function sameResult(first:PropertyEditResult, second:PropertyEditResult):Bool
		return switch ([first, second]) {
			case [Applied, Applied] | [Unchanged, Unchanged]: true;
			case [Rejected(_), Rejected(_)]: true;
			default: false;
		};

	/** The dialog's state: selection follows the filter, and the inspector is kept while nothing changes. */
	static function panel():Void {
		var changes = 0;
		var panel = new SettingsPanel("settings", new SettingsStore(catalogRegistry()), () -> changes++);
		check(panel.selectedCategory == "interface/editor", "the first category starts selected");
		var inspector = shown(panel);
		check(inspector != null && inspector == panel.currentInspector(), "the inspector is kept between frames");
		check(inspector.sections.length == 4, "the inspector shows the category's sections");

		panel.select("interface/theme");
		check(panel.selectedCategory == "interface/theme" && changes > 0, "selecting a category reports a change");
		panel.select("interface");
		check(panel.selectedCategory == "interface/editor", "selecting a group selects its first category");
		panel.select("network");
		check(panel.selectedCategory == "network", "a one-segment category is selectable");

		panel.setFilter("font");
		check(panel.categories().join(",") == "interface/editor", "the filter narrows the tree");
		check(panel.selectedCategory == "interface/editor", "a selection the filter hides moves to the first match");
		check(panel.currentInspector() != inspector, "a new filter builds a new inspector");
		check(shown(panel).sections[0].descriptors.length == 2, "and it shows the matches");

		panel.setFilter("nothing matches this");
		check(panel.selectedCategory == null && panel.currentInspector() == null, "no match, nothing selected");
		panel.setFilter("");
		check(panel.selectedCategory == "interface/editor", "clearing the filter selects again");

		var before = panel.currentInspector();
		panel.setShowAdvanced(true);
		check(panel.showAdvanced && panel.currentInspector() != before, "the Advanced switch rebuilds the inspector");
		check(shown(panel).sections[1].descriptors.length == 2, "and shows advanced settings");
	}

	static function shown(panel:SettingsPanel):PropertyInspector {
		var inspector:Null<PropertyInspector> = panel.currentInspector();
		if (inspector == null)
			throw "the panel shows no inspector";
		return inspector;
	}

	static function shortcutNames():Void {
		var save = new Shortcut(UiKey.S, UiModifier.Control | UiModifier.Shift);
		check(save.label() == "Ctrl+Shift+S" && save.serialize() == "ctrl+shift+s", 'names: ${save.label()} ${save.serialize()}');
		check(new Shortcut(UiKey.Comma, UiModifier.Control).label() == "Ctrl+,", "punctuation shows as itself");
		check(new Shortcut(UiKey.F5).label() == "F5" && new Shortcut(UiKey.Escape).label() == "Esc", "F-keys and named keys");
		for (shortcut in [save, new Shortcut(UiKey.Comma, UiModifier.Control), new Shortcut(UiKey.F10, UiModifier.Alt),
			new Shortcut(49, UiModifier.Super), new Shortcut(UiKey.PageDown), new Shortcut(123456, UiModifier.Control)])
			check(shortcut.equals(Shortcut.parse(shortcut.serialize())), "round trip: " + shortcut.serialize());
		check(Shortcut.parse("CTRL+S") != null, "parsing ignores case");
		for (bad in ["", "ctrl+", "hyper+s", "ctrl+nosuchkey", "f0", "key-3", "ctrl+key340"])
			check(Shortcut.parse(bad) == null, "rejected: " + bad);
		check(Shortcut.isModifierKey(340) && Shortcut.isModifierKey(347) && !Shortcut.isModifierKey(UiKey.S), "modifier keys");
	}

	static function sampleCommands(log:Array<String>):CommandRegistry {
		var commands = new CommandRegistry();
		commands.register(new Command("editor.save", "Save", () -> log.push("save"), new Shortcut(UiKey.S, UiModifier.Control)));
		var palette = new Command("editor.palette", "Command Palette", () -> log.push("palette"), new Shortcut(UiKey.K, UiModifier.Control));
		palette.addShortcut(new Shortcut(UiKey.P, UiModifier.Control));
		commands.register(palette);
		commands.register(new Command("scene.frame", "Frame Selected", () -> log.push("frame")));
		commands.register(new Command("viewport.save", "Save View", () -> log.push("view"), new Shortcut(UiKey.S, UiModifier.Control)), "viewport");
		return commands;
	}

	static function customShortcuts():Void {
		var log:Array<String> = [];
		var commands = sampleCommands(log);
		check(commands.shortcutsFor("editor.palette").length == 2, "registered shortcuts, primary first");
		commands.setShortcuts("scene.frame", [new Shortcut(UiKey.F2)]);
		check(commands.dispatch(UiKey.F2, 0) && log.join(",") == "frame", "a custom binding runs its command");
		commands.setShortcuts("editor.save", []);
		check(!commands.dispatch(UiKey.S, UiModifier.Control) && log.length == 1, "an unbound command no longer runs");
		commands.resetShortcuts("editor.save");
		check(commands.dispatch(UiKey.S, UiModifier.Control) && log[1] == "save", "reset restores the registered shortcut");
		commands.setShortcuts("editor.palette", [new Shortcut(UiKey.K, UiModifier.Control), new Shortcut(UiKey.P, UiModifier.Control)]);
		check(!commands.hasCustomShortcuts("editor.palette"), "choosing the registered shortcuts is not a custom binding");
		check(commands.commandsBoundTo(new Shortcut(UiKey.S, UiModifier.Control)).join(",") == "editor.save", "lookup stays in its scope");
		check(commands.commandsBoundTo(new Shortcut(UiKey.S, UiModifier.Control), "viewport").join(",") == "viewport.save",
			"other scopes are separate");
		commands.setShortcuts("plugin.later", [new Shortcut(UiKey.F5)]);
		check(commands.customShortcutIds().indexOf("plugin.later") >= 0, "bindings for commands not registered yet are kept");
		commands.register(new Command("plugin.later", "Later", () -> log.push("later")));
		check(commands.dispatch(UiKey.F5, 0) && log[2] == "later", "and apply once the command is registered");
	}

	static function shortcutPersistence():Void {
		var file = prepareFile("shortcuts.json");
		var log:Array<String> = [];
		var bindings = new ShortcutBindings(sampleCommands(log), new SettingsStore(sampleRegistry(), file));
		bindings.assign("scene.frame", new Shortcut(UiKey.F2, UiModifier.Shift));
		bindings.clear("editor.palette");
		var reopened = new ShortcutBindings(sampleCommands(log), new SettingsStore(sampleRegistry(), file));
		check(reopened.commands.shortcutsFor("scene.frame")[0].label() == "Shift+F2", "a new binding survives a restart");
		check(reopened.commands.shortcutsFor("editor.palette").length == 0, "an unbound command stays unbound");
		check(!reopened.commands.hasCustomShortcuts("editor.save"), "untouched commands are not saved");
		reopened.resetAll();
		check(new SettingsStore(sampleRegistry(), file).getState(ShortcutBindings.STATE_KEY) == null, "resetting everything saves nothing");

		// Taking a chord from another command in the same scope, and only there.
		var taking = new ShortcutBindings(sampleCommands(log), new SettingsStore(sampleRegistry()));
		var taken = taking.assign("scene.frame", new Shortcut(UiKey.S, UiModifier.Control));
		check(taken.join(",") == "editor.save", "the chord is taken from the command that had it");
		check(taking.commands.shortcutsFor("editor.save").length == 0, "which is left without it");
		check(taking.commands.shortcutsFor("viewport.save").length == 1, "a command in another scope keeps it");

		// Unreadable saved values are skipped.
		var store = new SettingsStore(sampleRegistry());
		var saved:Dynamic = {};
		Reflect.setField(saved, "editor.save", ["nonsense"]);
		Reflect.setField(saved, "scene.frame", "ctrl+f");
		var none:Array<String> = [];
		Reflect.setField(saved, "editor.palette", none);
		store.setState(ShortcutBindings.STATE_KEY, saved);
		var junk = new ShortcutBindings(sampleCommands(log), store);
		check(!junk.commands.hasCustomShortcuts("editor.save") && !junk.commands.hasCustomShortcuts("scene.frame"),
			"unreadable bindings fall back to the registered shortcuts");
		check(junk.commands.shortcutsFor("editor.palette").length == 0, "an empty list still means unbound");
	}

	static function shortcutsPanel():Void {
		var log:Array<String> = [];
		var changes = 0;
		var panel = new ShortcutsPanel("shortcuts", new ShortcutBindings(sampleCommands(log), new SettingsStore(sampleRegistry())),
			() -> changes++);
		var groups = panel.groups();
		check([for (group in groups) group.name].join(",") == "editor,scene,viewport", "commands are grouped by ID prefix");
		check(panel.shortcutText("editor.palette") == "Ctrl+K, Ctrl+P" && panel.shortcutText("scene.frame") == "None",
			"shortcut text");

		check(!panel.press(UiKey.F2, 0), "keys are ignored until a row records");
		panel.record("scene.frame");
		check(panel.recordingId == "scene.frame" && changes == 1, "clicking a shortcut starts recording");
		check(panel.press(340, UiModifier.Shift) && panel.recordingId == "scene.frame", "a modifier alone keeps waiting");
		check(panel.press(70, UiModifier.Shift | UiModifier.CapsLock) && panel.recordingId == null, "a chord is recorded");
		check(panel.shortcutText("scene.frame") == "Shift+F", "lock keys are not part of the chord");

		panel.record("scene.frame");
		check(panel.press(UiKey.Escape, 0) && panel.shortcutText("scene.frame") == "Shift+F", "Escape cancels recording");

		panel.record("scene.frame");
		panel.press(UiKey.S, UiModifier.Control);
		check(panel.notice == "Ctrl+S was moved from Save.", 'moving a chord is explained: ${panel.notice}');
		panel.reset("editor.save");
		check(panel.notice == "Ctrl+S is also used by Frame Selected.", 'a reset that clashes is explained: ${panel.notice}');

		panel.clear("editor.palette");
		check(panel.shortcutText("editor.palette") == "None", "clear removes every shortcut");

		panel.setFilter("ctrl+s");
		check([for (group in panel.groups()) group.ids.join(",")].join(";") == "editor.save;scene.frame;viewport.save",
			'the filter matches shortcuts: ${[for (group in panel.groups()) group.ids.join(",")].join(";")}');
		panel.setFilter("palette");
		check(panel.groups().length == 1 && panel.groups()[0].ids[0] == "editor.palette", "and names");
	}
}
