package nativekit.ui.docking;

import nativekit.ui.core.Command;
import nativekit.ui.core.CommandRegistry;
import nativekit.ui.core.CommandResult;

/** Registers command adapters for a workspace model. */
class DockWorkspaceCommands {
	public static function install(model:DockWorkspaceModel, registry:CommandRegistry,
			prefix:String = "dock", scope:String = CommandRegistry.GlobalScope):Void {
		if (model == null || registry == null || prefix == null || prefix.length == 0)
			throw "Dock commands require a workspace, registry, and stable prefix";
		registry.register(Command.contextual(prefix + ".close", "Close panel", function(context) {
			var panelId = context.parameters.getString("panel");
			if (panelId == null)
				panelId = model.activePanelId;
			return panelId != null && model.close(panelId) ? CommandResult.executed() :
				CommandResult.rejected("The active panel cannot be closed");
		}, null, function(context) {
			var panelId = context.parameters.getString("panel");
			if (panelId == null)
				panelId = model.activePanelId;
			var panel = panelId == null ? null : model.get(panelId);
			return panel != null && panel.closable && model.isOpen(panelId);
		}), scope);
		registry.register(Command.contextual(prefix + ".reset", "Reset workspace", function(_) {
			model.reset();
			return CommandResult.executed();
		}), scope);
	}
}
