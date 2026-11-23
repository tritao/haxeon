import haxeon.ui.Color;
import haxeon.ui.Insets;
import haxeon.ui.LayoutAlignmentY;
import haxeon.ui.LayoutAxis;
import haxeon.ui.LayoutStyle;
import haxeon.ui.core.BuildContext;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.View;
import haxeon.ui.widgets.KeyedView;
import haxeon.ui.widgets.controls.Button;
import haxeon.ui.widgets.layout.Row;
import haxeon.ui.widgets.text.Text;

class CircuitHud implements View {
	public static inline var height = 56;

	final game:Circuit;
	final soundEnabled:Void->Bool;
	final restart:Void->Void;
	final toggleSound:Void->Void;

	public function new(game:Circuit, soundEnabled:Void->Bool, restart:Void->Void, toggleSound:Void->Void) {
		this.game = game;
		this.soundEnabled = soundEnabled;
		this.restart = restart;
		this.toggleSound = toggleSound;
	}

	public function build(buildContext:BuildContext):RenderNode {
		var style = new LayoutStyle();
		style.width = LayoutAxis.grow();
		style.height = LayoutAxis.fixed(height);
		style.padding = new Insets(12, 0, 12, 0);
		style.childAlignY = LayoutAlignmentY.Center;
		style.childGap = 12;
		style.background = Color.rgba(0.09, 0.12, 0.19, 1);
		var status = switch game.state {
			case Playing: "Nodes left: " + game.remaining;
			case Finished(Captured): "Caught · " + game.remaining + " left";
			case Finished(Cleared): "Maze cleared";
		};
		var labelStyle = new LayoutStyle();
		labelStyle.width = LayoutAxis.grow();
		return new Row("hud", [
			new KeyedView("status", new Text(status, labelStyle, Color.rgba(0.94, 0.96, 1, 1))),
			new KeyedView("sound",
				new Button(soundEnabled() ? "Sound on" : "Sound off", null, toggleSound, "sound")),
			new KeyedView("restart", new Button("Restart", null, restart, "restart"))
		], style).build(buildContext);
	}
}
