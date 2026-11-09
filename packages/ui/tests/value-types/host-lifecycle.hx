import haxeon.ui.host.UiHostSession;
import haxeon.ui.host.UiHostSession.UiHostLifecycle;

@:access(haxeon.ui.host.UiHostSession)
private class LifecycleProbe {
	public static function run():Int {
		var stops = 0;
		var session = new UiHostSession(function() stops++);
		if (session.state != UiHostLifecycle.Starting || !session.isActive()) return 1;
		session.transition(UiHostLifecycle.LoadingResources);
		if (session.state != UiHostLifecycle.LoadingResources || !session.isActive()) return 2;
		session.transition(UiHostLifecycle.Running);
		session.transition(UiHostLifecycle.Running);
		if (session.state != UiHostLifecycle.Running || !session.isActive()) return 3;
		session.stop();
		session.stop();
		session.dispose();
		if (session.state != UiHostLifecycle.Stopping || session.isActive() || stops != 1) return 4;
		session.transition(UiHostLifecycle.Stopped);
		if (session.state != UiHostLifecycle.Stopped || session.isActive()) return 5;
		var rejected = false;
		try session.transition(UiHostLifecycle.Running) catch (_:Dynamic) rejected = true;
		if (!rejected) return 6;
		var failed = new UiHostSession(function() stops++);
		failed.transition(UiHostLifecycle.Failed);
		failed.stop();
		if (failed.state != UiHostLifecycle.Failed || failed.isActive() || stops != 1) return 7;
		return 42;
	}
}

function main():Int return LifecycleProbe.run();
