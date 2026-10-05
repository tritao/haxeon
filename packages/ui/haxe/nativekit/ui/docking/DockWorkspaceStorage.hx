package nativekit.ui.docking;

/** Adapts a workspace model to an application-owned persistence service. */
class DockWorkspaceStorage {
	public static function save(model:DockWorkspaceModel, storage:DockWorkspacePersistence,
			key:String):Void {
		validate(model, storage, key);
		storage.save(key, model.snapshotJson());
	}

	public static function restore(model:DockWorkspaceModel, storage:DockWorkspacePersistence,
			key:String):Bool {
		validate(model, storage, key);
		return model.restoreJson(storage.load(key));
	}

	/** Falls back to the model's default layout when saved state is invalid. */
	public static function restoreOrDefault(model:DockWorkspaceModel,
			storage:DockWorkspacePersistence, key:String):Bool {
		if (restore(model, storage, key))
			return true;
		model.reset();
		return false;
	}

	static function validate(model:DockWorkspaceModel, storage:DockWorkspacePersistence,
			key:String):Void {
		if (model == null || storage == null || key == null || key.length == 0)
			throw "Dock workspace storage requires a model, storage, and stable key";
	}
}
