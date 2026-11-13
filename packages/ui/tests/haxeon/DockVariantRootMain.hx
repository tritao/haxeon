import haxeon.ui.core.UiContext;
import haxeon.ui.core.RenderNode;
import haxeon.ui.LayoutFrame;
import haxeon.ui.LayoutSession;
import haxeon.ui.FontCollection;
import haxeon.ui.docking.DockNode;
import haxeon.ui.docking.DockSplitAxis;
import haxeon.ui.docking.DockWorkspaceModel;
import haxeon.ui.docking.DockPanelDescriptor;
import haxeon.ui.widgets.docking.DockWorkspace;
import haxeon.ui.widgets.docking.DockPanelContent;
import haxeon.ui.widgets.text.Text;
import haxeon.ui.semantics.AccessibilityRole;

class DockVariantRootMain {
  static function main():Int {
    var fonts = FontCollection.create();
    fonts.add(Sys.getEnv("NKUI_TEST_FONT_PATH"));
    var session = LayoutSession.create();
    var ui = new UiContext(session, fonts);
    if (!run(ui)) throw "Dock variant final model callback mismatch";
    ui.dispose();
    session.dispose();
    fonts.dispose();
    return 42;
  }
  public static function run(uiContext:UiContext):Bool {
    var model = new DockWorkspaceModel();
    for (id in ["pane-a", "pane-b"]) model.register(new DockPanelDescriptor(id, id));
    model.setRoot(DockNode.Tabs(["pane-a", "pane-b"], "pane-a"));
    var workspace = new DockWorkspace(
      "pane-variants",
      model,
      [
        DockPanelContent.observing("pane-a", _ -> new Text("A content")),
        DockPanelContent.observing("pane-b", _ -> new Text("B content"))
      ]
    );
    var frame = new LayoutFrame(640.0, 480.0);
    function tabs(root:RenderNode):Null<RenderNode> {
      var found:Null<RenderNode> = null;
      root.walk(function(node) {
        if (node.styleType == "tabs") found = node;
      }
      );
      return found;
    }
    function hasText(root:RenderNode, value:String):Bool {
      var found = false;
      root.walk(function(node) {
        if (node.layout.text == value) found = true;
      }
      );
      return found;
    }
    function clickTab(root:RenderNode, label:String):Bool {
      var target:Null<RenderNode> = null;
      root.walk(function(node) {
        if (node.semantics != null
          && node.semantics.role == AccessibilityRole.Tab && node.semantics.label == label) target = node;
      }
      );
      if (target == null) throw "Dock variant stage 1";
      var bounds = target.globalBounds();
      uiContext.pointerDown(bounds.x + bounds.width * 0.5, bounds.y + bounds.height * 0.5, 0);
      uiContext.pointerUp(bounds.x + bounds.width * 0.5, bounds.y + bounds.height * 0.5, 0);
      return true;
    }
    var first = uiContext.submit(workspace, frame), firstTabs = tabs(first);
    var originalNative:Array<RenderNode> = [];
    var originalParents:Array<Null<RenderNode>> = [];
    first.walk(node -> {if (node.scopeOwner() != null) {
      originalNative.push(node);
      originalParents.push(node.parent);
    }
    });
    if (firstTabs == null || !hasText(first, "A content") || !clickTab(first, "pane-b")) throw "Dock variant stage 2";
    var second = uiContext.submit(workspace, frame);
    for (index in 0...originalNative.length) {
      var node = originalNative[index];
      var owner = node.scopeOwner();
      if (owner == null || owner.disposed) throw "Cached pane native owner disposed by another variant";
      var current = uiContext.buildContext.currentRoot(node);
      var parent = originalParents[index];
      if (parent != null) parent = uiContext.buildContext.currentRoot(parent);
      if (current.parent != parent) throw "Cached native root redirected into a different pane";
    }
    if (!hasText(second, "B content") || !clickTab(second, "pane-a")) throw "Dock variant stage 3";
    var returned = uiContext.submit(workspace, frame);
    if (tabs(returned) != firstTabs || !hasText(returned, "A content")) throw "Dock variant stage 4";
    if (!uiContext.buildContext.requestPatch(firstTabs.id)) throw "Dock variant stage 5";
    uiContext.submit(workspace, frame);
    if (uiContext.verifyRetention(() -> workspace, frame) != null) throw "Dock variant stage 6";
    // Moving retained panel content away invalidates any hidden pane that used its former parent.
    model.setRoot(DockNode.Split(DockSplitAxis.Horizontal, 0.5, DockNode.Panel("pane-a"), DockNode.Panel("pane-b")));
    uiContext.submit(workspace, frame);
    model.setRoot(DockNode.Tabs(["pane-a", "pane-b"], "pane-a"));
    var moved = uiContext.submit(workspace, frame);
    if (!hasText(moved,
      "A content") || uiContext.verifyRetention(() -> workspace, frame) != null) throw "Dock variant stage 7";
    // Matching panel names and revisions do not make callbacks from another model interchangeable.
    var replacement = new DockWorkspaceModel();
    for (id in ["pane-a", "pane-b"]) replacement.register(new DockPanelDescriptor(id, id));
    replacement.setRoot(DockNode.Tabs(["pane-a", "pane-b"], "pane-a"));
    var replacementWorkspace = new DockWorkspace(
      "pane-variants",
      replacement,
      [
        DockPanelContent.observing("pane-a", _ -> new Text("replacement A")),
        DockPanelContent.observing("pane-b", _ -> new Text("replacement B"))
      ]
    );
    var replacementRoot = uiContext.submit(replacementWorkspace, frame), target:Null<RenderNode> = null;
    replacementRoot.walk(function(node) {
      if (node.semantics != null
        && node.semantics.role == AccessibilityRole.Tab && node.semantics.label == "pane-b") target = node;
    }
    );
    if (!hasText(replacementRoot, "replacement A") || target == null) throw "Dock variant stage 8";
    var bounds = target.globalBounds();
    uiContext.pointerDown(bounds.x + bounds.width * 0.5, bounds.y + bounds.height * 0.5, 0);
    uiContext.pointerUp(bounds.x + bounds.width * 0.5, bounds.y + bounds.height * 0.5, 0);
    return replacement.activePanelId == "pane-b" && model.activePanelId == "pane-a";
  }

}
