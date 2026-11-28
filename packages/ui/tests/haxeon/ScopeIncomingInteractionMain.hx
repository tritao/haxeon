import haxeon.reactive.Signal;
import haxeon.ui.LayoutChanges;
import haxeon.ui.LayoutFrame;
import haxeon.ui.LayoutNode;
import haxeon.ui.LayoutSession;
import haxeon.ui.ResolvedLayoutItem;
import haxeon.ui.component.TrackedScope;
import haxeon.ui.core.BuildContext;
import haxeon.ui.core.Key;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.UiContext;
import haxeon.ui.core.View;
import haxeon.ui.core.ViewRoot;
import haxeon.ui.core.WidgetId;
import haxeon.ui.style.StyleIdentity;
import haxeon.ui.style.StyleState;

/** A retained incoming owner must receive interactions queued against the outgoing physical instance. */
@:access(haxeon.ui.core.RenderNode) @:access(haxeon.ui.core.EventDispatcher) @:access(haxeon.ui.core
	.UiContext) @:access(haxeon.ui.core.ViewRoot) class ScopeIncomingInteractionMain implements View {
	final version = new Signal<Int>(0);
	final fresh:Bool;
	final flag:StyleState;
	var incoming:RenderNode;
	var outgoing:RenderNode;
	var incomingIds:Array<ResourceId>;
	var outgoingIds:Array<ResourceId>;

	public function new(fresh:Bool, flag:StyleState) {
		this.fresh = fresh;
		this.flag = flag;
	}

	public function build(context:BuildContext):ViewRoot {
		var selected = version.value;
		context.retainStateIds(incomingIds);
		context.retainStateIds(outgoingIds);
		var root = context.createNode(context.rootId("holder"), LayoutVisualKind.Box);
		var child = selected == 0 ? outgoing : fresh ? leaf(context, flag) : incoming;
		if (selected == 0 || !fresh) context.claimRetainedTree(child);
		root.add(child);
		return root;
	}

	static function leaf(context:BuildContext, flag:StyleState):RenderNode {
		return new TrackedScope("same-slot", () -> new InteractionLeaf(flag)).build(context).node();
	}

	static function seedLeaf(context:BuildContext, flag:StyleState, nested:Bool):RenderNode {
		return context.withScope(new Key("root"),
			() -> nested ? context.withScope(new Key("parent-branch"), () -> leaf(context, flag)) : leaf(context,
			flag));
	}

	static function runCase(fresh:Bool, flag:StyleState, enter:Bool, routeAlias:Bool = false,
			nested:Bool = false):Void {
		var session = new InteractionLayoutSession(enter);
		var ui = new UiContext(session), context = ui.buildContext;
		var view = new ScopeIncomingInteractionMain(fresh, flag);
		var top:View = nested ? new TrackedScope("parent-branch", () -> view) : view;
		var frame = new LayoutFrame(300, 80);
		context.setViewport(300, 80);
		context.setEnvironmentViewport(300, 80);
		context.beginFrame();
		var marker = context.stateUsageMarker();
		view.incoming = seedLeaf(context, flag, nested);
		view.incomingIds = context.stateIdsUsedSince(marker);
		if (!enter) {
			ui.interactionStates.set(view.incoming.id, flag);
			context.renderScopeAt(view.incoming).markDirty();
			context.flushRenderScopes(view.incoming);
			view.incoming = context.currentRoot(view.incoming);
		}
		ui.stateStore.endFrame();
		context.beginFrame();
		context.retainStateIds(view.incomingIds);
		marker = context.stateUsageMarker();
		view.outgoing = seedLeaf(context, flag, nested);
		view.outgoingIds = context.stateIdsUsedSince(marker);
		if (!view.incoming.id.equals(view.outgoing.id)) throw "Fixture needs two physical owners of one logical slot";
		ui.stateStore.endFrame();
		context.beginFrame();
		ui.root = context.trackReads(() -> context.withScope(new Key("root"), () -> top.build(context).node()));
		context.captureRootDependencies();
		ui.stateStore.endFrame();
		ui.root.walk(node -> {
			ui.submittedNodes.push(node);
			ui.submittedTopology.append(node);
			ui.currentNodesById.set(node.id.value, node);
		});
		ui.submittedBuildKey = "incoming";
		ui.submittedFrameWidth = 300;
		ui.submittedFrameHeight = 80;
		ui.submittedInteractionRevision = ui.interactionStates.revision;
		ui.submittedStyleRevision = context.styleRevision;
		ui.submittedGestureRevision = ui.gestures.revision;
		ui.submittedTheme = context.theme;
		ui.submittedStyleSheet = context.styleSheet;
		view.outgoing.contentRevision = 20;
		ui.interactionStates.acknowledge();
		if (routeAlias) {
			ui.events.setRoot(ui.root, ui.currentNodesById);
			ui.events.setState(view.incoming, flag, enter);
		} else ui.interactionStates.set(view.outgoing.id, enter ? flag : StyleState.empty());
		view.version.value = 1;
		if (context.rootDependenciesDirty()
			== nested) throw "Fixture did not select its intended root/ancestor update path";
		var before = InteractionLeaf.builds;
		var reached = false;
		try ui.submitCached(() -> top, frame, "incoming") catch (error:Dynamic) {
			if (Std.string(error) != "incoming layout boundary") throw error;
			reached = true;
		}
		ui.stateStore.dispose();
		context.dispose();
		if (!reached || !session.matched) throw "Incoming cached scope missed the pending interaction: flag="
			+ flag.rawValue + " enter=" + enter + " nested=" + nested;
		if (session.revision < 20) throw "Incoming cached node reset the submitted revision: " + session.revision;
		if (InteractionLeaf.builds != before + 1) throw "Incoming interaction rebuilt its body more than once";
	}

	static function main():Int {
		runCase(false, StyleState.Pressed, true, false, true);
		runCase(true, StyleState.Pressed, true, false, true);
		runCase(false, StyleState.Pressed, true, true);
		runCase(false, StyleState.Hovered, true);
		runCase(true, StyleState.Hovered, true);
		runCase(false, StyleState.Hovered, false);
		runCase(true, StyleState.Hovered, false);
		runCase(false, StyleState.Pressed, true);
		runCase(true, StyleState.Pressed, true);
		return 42;
	}
}

@:access(haxeon.ui.core.ViewRoot) private class InteractionLeaf implements View {
	public static var builds = 0;

	final flag:StyleState;

	public function new(flag:StyleState) {
		this.flag = flag;
	}

	public function build(context:BuildContext):ViewRoot {
		builds++;
		var id = context.rootId("leaf");
		var node = context.createNode(id, LayoutVisualKind.Box);
		node.setStyleIdentity(new StyleIdentity("button", "fixture", "fixture", null, ["button"]));
		node.states = context.interactionStates.get(id);
		node.layout.style.zIndex = node.states.contains(flag) ? 2 : 1;
		return node;
	}
}

@:access(haxeon.ui.LayoutSession) @:access(haxeon.ui.core
	.ViewRoot) private class InteractionLayoutSession extends LayoutSession {
	public var matched = false;
	public var revision = 0;

	final expected:Int;

	public function new(enter:Bool) {
		super(cast 0);
		expected = enter ? 2 : 1;
	}

	// A frame lays its tree out through solve before it publishes; stopping there sees the tree layout was given.
	override function solve(root:LayoutNode, frame:LayoutFrame, ?changes:LayoutChanges):Array<ResolvedLayoutItem> {
		matched = root.children.length == 1 && root.children[0].style.zIndex == expected;
		if (root.children.length == 1) revision = root.children[0].contentRevision;
		throw "incoming layout boundary";
	}
}
