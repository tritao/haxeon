package haxeon.ui.widgets.properties;
import haxeon.ui.widgets.controls.ButtonVariant;
import haxeon.ui.widgets.scroll.ScrollAxis;
import haxeon.ui.widgets.KeyedView;
import haxeon.ui.widgets.controls.Button;
import haxeon.ui.widgets.layout.Column;
import haxeon.ui.widgets.scroll.ScrollController;
import haxeon.ui.widgets.scroll.ScrollView;

import haxeon.ui.LayoutAxis;
import haxeon.ui.LayoutStyle;
import haxeon.ui.core.BuildContext;
import haxeon.ui.core.Key;
import haxeon.ui.properties.PropertyDescriptor;
import haxeon.ui.properties.PropertyEditorRegistry;
import haxeon.ui.properties.PropertyInspectorSection;
import haxeon.ui.properties.PropertyValue;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.View;
import haxeon.ui.icons.IconName;
import haxeon.ui.semantics.AccessibilityRole;
import haxeon.ui.semantics.Semantics;

/**
 * Shared scrollable inspector composition.
 *
 * Descriptors remain application-owned. This view only groups them into
 * stable sections and delegates row editing to PropertyEditor, preserving the
 * same binding, validation, custom-extension, and undo behavior.
 */
class PropertyInspector implements View {
  public final key:String;
  public final descriptors:Array<PropertyDescriptor>;
  public final sections:Array<PropertyInspectorSection>;
  public var style(default, null):LayoutStyle;
  public final registry:PropertyEditorRegistry;
  public var controller(default, null):ScrollController;
  public var enabled:Bool;
  public var labelWidth:Float;
  public var stackedRows:Bool = false;
  public var searchQuery:String = "";
  /** Disable when a parent pane already owns scrolling. */
  public var scrollable:Bool;
  public var showScrollbar:Bool;
  public var label:Null<String>;
  public var onSectionExpanded:Null<String -> Bool -> Void>;
  final editors:Map<String, PropertyEditor>;
  final sectionByDescriptor:Map<String, PropertyEditor>;
  final initialExpanded:Array<Bool>;
  final initialScrollX:Float;
  final initialScrollY:Float;

  public function new(
    key:String,
    ?descriptors:Array<PropertyDescriptor>,
    ?style:LayoutStyle,
    ?registry:PropertyEditorRegistry,
    ?sections:Array<PropertyInspectorSection>,
    ?controller:ScrollController,
    ?label:String
  ) {
    if (key == null || key.length == 0) throw "Property inspectors require a stable key";
    this.key = key;
    this.registry = registry == null ? new PropertyEditorRegistry() : registry;
    this.sections = sections == null ? groupDescriptors(descriptors == null ? [] : descriptors) : sections.copy();
    if (this.sections.length == 0) throw "Property inspectors require at least one section";
    this.descriptors = collectDescriptors(this.sections);
    if (descriptors != null && sections != null) validateDescriptorSet(descriptors, this.descriptors);
    this.style = style == null ? defaultStyle() : style.copy();
    this.controller = controller == null ? new ScrollController() : controller;
    initialScrollX = this.controller.offsetX;
    initialScrollY = this.controller.offsetY;
    initialExpanded = [for (section in this.sections) section.expanded];
    this.enabled = true;
    this.labelWidth = 140.0;
    this.scrollable = true;
    this.showScrollbar = true;
    this.label = label == null ? "Inspector" : label;
    this.onSectionExpanded = null;
    this.editors = new Map();
    this.sectionByDescriptor = new Map();
    for (section in this.sections) {
      if (editors.exists(section.id)) throw "Inspector section IDs must be unique";
      var editor = new PropertyEditor("section:" + section.id, section.descriptors, null, this.registry);
      editor.showCategoryHeaders(false);
      editors.set(section.id, editor);
      for (descriptor in section.descriptors) {
        if (sectionByDescriptor.exists(descriptor.id)) throw "Inspector descriptor IDs must be unique across sections";
        sectionByDescriptor.set(descriptor.id, editor);
      }
    }
  }

  /** Updates the container style without discarding editor drafts or section state. */
  public function setStyle(next:LayoutStyle):Void {
    if (next == null) throw "Property inspector style cannot be null";
    style = next.copy();
  }

  /** Changes a section's expansion state for the next submitted frame. */
  public function setSectionExpanded(sectionId:String, expanded:Bool):Bool {
    var section = findSection(sectionId);
    if (section == null) throw 'Unknown inspector section: $sectionId';
    var changed = section.setExpanded(expanded);
    if (changed && onSectionExpanded != null) onSectionExpanded(section.id, section.expanded);
    return changed;
  }

  public function isSectionExpanded(sectionId:String):Bool {
    var section = findSection(sectionId);
    return section != null && section.expanded;
  }

  /** Revision of transient editor state that must invalidate a retained panel. */
  /** Whether discarding and rebuilding this inspector would keep all of its transient user state unchanged. */
  public function isPristine():Bool {
    if (sections.length != initialExpanded.length || controller.offsetX != initialScrollX
      || controller.offsetY != initialScrollY || controller.advance(0.0)) return false;
    for (index in 0...sections.length) {
      var section = sections[index], editor = editors.get(section.id);
      if (section.expanded != initialExpanded[index] || editor == null || !editor.isPristine()) return false;
    }
    return true;
  }

  /** Current validation/transaction error for a descriptor, if any. */
  public function errorFor(descriptorId:String):Null<String> {
    var editor = sectionByDescriptor.get(descriptorId);
    return editor == null ? null : editor.errorFor(descriptorId);
  }

  /** Applies through the row editor assigned to the descriptor's section. */
  public function applyValue(
    context:BuildContext,
    descriptor:PropertyDescriptor,
    value:PropertyValue,
    ?coalesceKey:String
  ):Bool {
    if (descriptor == null) return false;
    var editor = sectionByDescriptor.get(descriptor.id);
    return editor == null ? false : editor.applyValue(context, descriptor, value, coalesceKey);
  }

  public function build(context:BuildContext):RenderNode {
    var observed = context.buildProbe != null;
    var started = observed ? Sys.time() : 0.0;
    var result = context.withScope(new Key(key), function() {
      var children:Array<KeyedView> = [];
      for (section in sections) {
        var editor = editors.get(section.id);
        editor.configure(enabled, labelWidth, stackedRows, searchQuery);
        var header = new PropertyInspectorSectionHeader("header", section, function() {
          setSectionExpanded(section.id, !section.expanded);
        }
        );
        children.push(new KeyedView("section:" + section.id + ":header", header));
        if (section.expanded) children.push(new KeyedView("section:" + section.id + ":body", editor));
      }
      var contentStyle = scrollable ? new LayoutStyle() : style.copy();
      if (scrollable) {
        contentStyle.width = LayoutAxis.grow();
        contentStyle.height = LayoutAxis.fit();
      }
      contentStyle.childGap = 6.0;
      var content = new Column("sections", children, contentStyle);
      if (!scrollable) {
        var root = content.build(context);
        root.semantics = new Semantics(AccessibilityRole.Group, label);
        return root;
      }
      var scroll = new ScrollView("viewport", content, style, ScrollAxis.Vertical, controller);
      scroll.showScrollbar = showScrollbar;
      var root = scroll.build(context);
      if (root.semantics == null) root.semantics = new Semantics(AccessibilityRole.ScrollArea, label);
      else root.semantics.label = label;
      return root;
    }
    );
    if (observed) context.reportBuild("inspector:" + key, 0.0, Sys.time() - started, result);
    return result;
  }

  function findSection(sectionId:String):Null<PropertyInspectorSection> {
    if (sectionId == null) return null;
    for (section in sections) if (section.id == sectionId) return section;
    return null;
  }

  static function groupDescriptors(descriptors:Array<PropertyDescriptor>):Array<PropertyInspectorSection> {
    var result:Array<PropertyInspectorSection> = [];
    var byCategory:Map<String, Array<PropertyDescriptor>> = new Map();
    var categoryIds:Map<String, String> = new Map();
    var categoryOrder:Array<String> = [];
    for (descriptor in descriptors == null ? [] : descriptors) {
      if (descriptor == null) throw "Inspector descriptors cannot be null";
      var category = descriptor.category == null || descriptor.category.length == 0 ? "General" : descriptor.category;
      var id = category == "General" ? "general" : "category:" + category;
      var values = byCategory.get(id);
      if (values == null) {
        values = [];
        byCategory.set(id, values);
        categoryIds.set(id, category);
        categoryOrder.push(id);
      }
      values.push(descriptor);
    }
    for (id in categoryOrder) result.push(new PropertyInspectorSection(id, categoryIds.get(id), byCategory.get(id)));
    return result;
  }

  static function collectDescriptors(sections:Array<PropertyInspectorSection>):Array<PropertyDescriptor> {
    var result:Array<PropertyDescriptor> = [];
    for (section in sections) if (section == null) throw "Inspector sections cannot be null";
    else for (descriptor in section.descriptors) result.push(descriptor);
    return result;
  }

  static function validateDescriptorSet(expected:Array<PropertyDescriptor>, actual:Array<PropertyDescriptor>):Void {
    if (expected.length != actual.length) throw "Inspector descriptors must match its sections";
    var ids:Map<String, Bool> = new Map();
    for (descriptor in expected) {
      if (descriptor == null || ids.exists(descriptor.id)) throw "Inspector descriptor IDs must be unique";
      ids.set(descriptor.id, true);
    }
    for (descriptor in actual) if (!ids.exists(descriptor.id)) throw "Inspector descriptors must match its sections";
  }

  static function defaultStyle():LayoutStyle {
    var result = new LayoutStyle();
    result.width = LayoutAxis.grow();
    result.height = LayoutAxis.grow();
    return result;
  }
}

private class PropertyInspectorSectionHeader implements View {
  final key:String;
  final section:PropertyInspectorSection;
  final onToggle:Void -> Void;

  public function new(key:String, section:PropertyInspectorSection, onToggle:Void -> Void) {
    this.key = key;
    this.section = section;
    this.onToggle = onToggle;
  }

  public function build(context:BuildContext):RenderNode {
    var style = new LayoutStyle();
    style.width = LayoutAxis.grow();
    // Keep the header's text inside its available width when the dock narrows.
    style.clipHorizontal = true;
    var button = new Button(
      section.label,
      style,
      onToggle,
      key,
      null,
      ButtonVariant.Secondary,
      null,
      ["inspector-section-header"],
      section.expanded ? IconName.ChevronDown : IconName.ChevronRight,
      null,
      null,
      null,
      null,
      null,
      14.0
    );
    return button.build(context);
  }
}
