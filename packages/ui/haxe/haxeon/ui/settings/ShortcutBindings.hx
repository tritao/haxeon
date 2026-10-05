package haxeon.ui.settings;

import haxeon.ui.core.CommandRegistry;
import haxeon.ui.core.Shortcut;

/**
 * The user's shortcut choices, kept in a command registry and saved in a
 * settings store's "shortcuts" state as {"command.id": ["ctrl+s", ...]}.
 *
 * Only commands whose bindings differ from their registered shortcuts are
 * saved. Bindings for commands this build does not register are kept.
 */
class ShortcutBindings {
	public static inline var STATE_KEY:String = "shortcuts";

	public final commands:CommandRegistry;
	public final store:SettingsStore;

	public function new(commands:CommandRegistry, store:SettingsStore) {
		if (commands == null || store == null)
			throw "Shortcut bindings require a command registry and a settings store";
		this.commands = commands;
		this.store = store;
		load();
	}

	/**
	 * Makes the shortcut the command's only binding. Any other command in the
	 * same scope that used it loses it, so one chord never means two things;
	 * returns the IDs it was taken from.
	 */
	public function assign(id:String, shortcut:Shortcut):Array<String> {
		if (shortcut == null)
			throw "Assign a shortcut, or clear the command instead";
		var scope = commands.scopeOf(id);
		var taken:Array<String> = [];
		if (scope != null)
			for (other in commands.commandsBoundTo(shortcut, scope)) {
				if (other == id)
					continue;
				commands.setShortcuts(other, [for (existing in commands.shortcutsFor(other)) if (!existing.equals(shortcut)) existing]);
				taken.push(other);
			}
		commands.setShortcuts(id, [shortcut]);
		save();
		return taken;
	}

	/** Leaves the command without any shortcut. */
	public function clear(id:String):Void {
		commands.setShortcuts(id, []);
		save();
	}

	/** Restores the command's registered shortcuts. */
	public function reset(id:String):Void {
		commands.resetShortcuts(id);
		save();
	}

	public function resetAll():Void {
		for (id in commands.customShortcutIds())
			commands.resetShortcuts(id);
		save();
	}

	function load():Void {
		var saved:Dynamic = store.getState(STATE_KEY);
		if (saved == null || !Reflect.isObject(saved) || SettingsJsonValue.isArray(saved))
			return;
		for (id in Reflect.fields(saved)) {
			var names:Dynamic = Reflect.field(saved, id);
			if (!SettingsJsonValue.isArray(names))
				continue;
			var shortcuts:Array<Shortcut> = [];
			for (name in (names:Array<Dynamic>)) {
				var shortcut = SettingsJsonValue.isString(name) ? Shortcut.parse(name) : null;
				if (shortcut != null)
					shortcuts.push(shortcut);
			}
			// An empty list means "unbound"; a list of unreadable names means nothing usable was saved.
			if (shortcuts.length > 0 || (names:Array<Dynamic>).length == 0)
				commands.setShortcuts(id, shortcuts);
		}
	}

	function save():Void {
		var ids = commands.customShortcutIds();
		if (ids.length == 0) {
			store.setState(STATE_KEY, null);
			return;
		}
		ids.sort(function(first, second) return Reflect.compare(first, second));
		var saved:Dynamic = {};
		for (id in ids)
			Reflect.setField(saved, id, [for (shortcut in commands.shortcutsFor(id)) shortcut.serialize()]);
		store.setState(STATE_KEY, saved);
	}
}
