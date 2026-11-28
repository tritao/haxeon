package pages;

import components.ShowcaseKit;

import haxeon.ui.widgets.text.Text;


import UiExplorer;
import haxeon.ui.Color;
import haxeon.ui.Insets;
import haxeon.ui.LayoutAxis;
import haxeon.ui.LayoutStyle;
import haxeon.ui.core.View;
import haxeon.ui.gestures.GestureRecognizer;
import haxeon.ui.widgets.GestureDetector;
import haxeon.ui.widgets.KeyedView;
import haxeon.ui.widgets.layout.Padding;
import haxeon.ui.widgets.layout.Row;
import haxeon.ui.widgets.layout.Stack;

/** Gesture arbitration and Haxe-owned tween/spring motion demonstrations. */
class GesturesPage {
	public static function build(explorer:UiExplorer, items:Array<KeyedView>):Void {
		explorer.pageHeading(items,
			"Gestures & Motion",
			"Haxe recognizers arbitrate taps, holds and drags; frame-ticked tween and spring controllers animate ordinary UI state.");
		var stageStyle = explorer.panelStyle();
		stageStyle.height = LayoutAxis.fixed(174.0);
		var cardStyle = new LayoutStyle();
		cardStyle.width = LayoutAxis.grow();
		cardStyle.height = LayoutAxis.fixed(48.0);
		var buttonStyle = ShowcaseKit.buttonStyle();
		buttonStyle.width = LayoutAxis.grow();
		buttonStyle.height = LayoutAxis.fixed(48.0);
		var gestureCard = ShowcaseKit.button(explorer, "Touch, hold, or drag me", "gesture-card-button", () -> {
			explorer.state.gestures.message = "Button activation routed through the child view.";
		}, false, true, null, buttonStyle);
		var detector = new GestureDetector("gesture-playground-detector", gestureCard, [new TapRecognizer(_ -> {
			explorer.state.gestures.tapCount++;
			explorer.state.gestures.message = "Tap recognized.";
		}), new DoubleTapRecognizer(_ -> {
			explorer.state.gestures.doubleTapCount++;
			explorer.state.gestures.message = "Double tap recognized on the same target.";
		}), new LongPressRecognizer(_ -> {
			explorer.state.gestures.longPressCount++;
			explorer.state.gestures.message = "Long press recognized after a stationary hold.";
		}), new DragRecognizer(8.0, _ -> {
			explorer.state.gestures.dragCount++;
			explorer.state.gestures.dragOriginX = explorer.state.gestures.dragCardX;
			explorer.state.gestures.dragOriginY = explorer.state.gestures.dragCardY;
			explorer.state.gestures.message = "Drag won the gesture arena.";
		}, event -> {
			var sidebar = explorer.width < 760.0 ? 176.0 : 212.0;
			var inspectorWidth = explorer.state.inspector.open && explorer.width >= 880.0 ? 270.0 : 0.0;
			var maxX = Math.max(8.0, explorer.width - sidebar - inspectorWidth - 300.0);
			explorer.state.gestures.dragCardX = UiExplorer.clamp(explorer.state.gestures.dragOriginX + event.deltaX,
				8.0,
				maxX);
			explorer.state.gestures.dragCardY = UiExplorer.clamp(explorer.state.gestures.dragOriginY + event.deltaY,
				8.0,
				96.0);
		}, _ -> {
			explorer.state.gestures.message = "Drag ended.";
		})], cardStyle);
		items.push(explorer.keyed("gesture-playground",
			explorer.panel("gesture-playground-card",
			[
				explorer.keyed("heading", explorer.heading("Gesture arena")),
				explorer.keyed("copy",
					explorer.caption("Tap and double-tap the card, hold for a long press, or move past the drag threshold. A recognized drag cancels tap delivery.")),
				explorer.keyed("stage",
					new Stack("gesture-playground-stage",
					[new StackChild("draggable-card",
					detector,
					explorer.state.gestures.dragCardX,
					explorer.state.gestures.dragCardY,
					1,
					LayoutAxis.fixed(230.0),
					LayoutAxis.fixed(48.0))],
					stageStyle)),
				explorer.keyed("gesture-status",
					explorer.text(explorer.state.gestures.message, explorer.context.buildContext.theme.tokens.success)),
				explorer.keyed("gesture-counts",
					explorer.caption('Tap ${explorer.state.gestures.tapCount}  ·  Double tap ${explorer.state.gestures.doubleTapCount}  ·  Long press ${explorer.state.gestures.longPressCount}  ·  Drag ${explorer.state.gestures.dragCount}'))
			])));

		var motionStyle = explorer.panelStyle();
		motionStyle.height = LayoutAxis.fixed(132.0);
		var tweenX = 8.0 + explorer.state.gestures.tweenValue * 150.0;
		var springX = 8.0 + explorer.state.gestures.springValue * 150.0;
		items.push(explorer.keyed("motion-playground",
			explorer.panel("motion-playground-card", [explorer.keyed("heading",
			explorer.heading("Animated properties")), explorer.keyed("copy",
			explorer.caption("These cards move by rebuilding positioned layout from Haxe-owned tween and spring values.")),
			explorer.keyed("stage",
			new Stack("motion-stage",
			[
				new StackChild("tween-marker", motionMarker("Tween", UiExplorer.color(0.20, 0.52, 0.82)), tweenX, 12.0,
					1),
				new StackChild("spring-marker", motionMarker("Spring", UiExplorer.color(0.24, 0.58, 0.48)), springX,
					66.0, 1)
			],
			motionStyle)), explorer.keyed("actions", new Row("motion-actions",
			[explorer.keyed("tween", explorer.button("Replay tween", "gesture-replay-tween", () -> {
				explorer.tweenController.play(explorer.state.gestures.tweenValue,
					explorer.state.gestures.tweenValue < 0.5 ? 1.0 : 0.0,
					0.7);
			})), explorer.keyed("spring", explorer.button("Retarget spring", "gesture-retarget-spring", () -> {
			explorer.springController.setTarget(explorer.state.gestures.springValue < 0.5 ? 1.0 : 0.18);
		}))], explorer.rowStyle(10.0))), explorer.keyed("motion-values",
			explorer.caption('Tween ${Std.int(explorer.state.gestures.tweenValue * 100)}%  ·  Spring ${Std.int(explorer.state.gestures.springValue * 100)}%'))])));
	}

	static function motionMarker(label:String, background:Color):View {
		var style = new LayoutStyle();
		style.width = LayoutAxis.fixed(112.0);
		style.height = LayoutAxis.fixed(34.0);
		style.padding = new Insets(9.0, 6.0, 9.0, 6.0);
		style.background = background;
		style.radiusTopLeft = style.radiusTopRight = 5.0;
		style.radiusBottomLeft = style.radiusBottomRight = 5.0;
		return new Padding("motion-marker-padding",
			new haxeon.ui.widgets.text.Text(label, null, UiExplorer.color(1.0, 1.0, 1.0)),
			style.padding,
			style);
	}
}
