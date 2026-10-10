package audiolab;
import haxeon.ui.Renderer;

import haxeon.ui.Canvas;
import haxeon.ui.Color;
import haxeon.ui.Insets;
import haxeon.ui.LayoutAxis;
import haxeon.ui.LayoutAlignmentY;
import haxeon.ui.LayoutStyle;
import haxeon.ui.LayoutWrapMode;
import haxeon.ui.LineCap;
import haxeon.ui.LineJoin;
import haxeon.ui.PathBuilder;
import haxeon.ui.Rect;
import StringTools;
import haxeon.ui.core.BuildContext;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.View;
import haxeon.ui.theme.TextRole;
import haxeon.ui.widgets.controls.Button;
import haxeon.ui.widgets.controls.ButtonVariant;
import haxeon.ui.widgets.CanvasView;
import haxeon.ui.widgets.layout.Column;
import haxeon.ui.widgets.KeyedView;
import haxeon.ui.widgets.layout.Row;
import haxeon.ui.widgets.scroll.ScrollAxis;
import haxeon.ui.widgets.scroll.ScrollView;
import haxeon.ui.widgets.controls.Slider;
import haxeon.ui.widgets.text.Text;

/** NativeKit UI surface for the Audio Lab companion application. */
class AudioLabView implements View {
	public final lab:AudioLabEngine;
	public var screen:String = "synth";

	static final background:Color = Color.rgba(0.035, 0.045, 0.07, 1.0);
	static final panel:Color = Color.rgba(0.075, 0.09, 0.14, 1.0);
	static final panelRaised:Color = Color.rgba(0.10, 0.13, 0.20, 1.0);
	static final accent:Color = Color.rgba(0.31, 0.78, 0.95, 1.0);
	static final green:Color = Color.rgba(0.32, 0.88, 0.57, 1.0);
	static final muted:Color = Color.rgba(0.58, 0.65, 0.75, 1.0);
	static final white:Color = Color.rgba(0.92, 0.95, 1.0, 1.0);

	public function new(lab:AudioLabEngine) {
		if (lab == null)
			throw "Audio Lab view requires an engine";
		this.lab = lab;
	}

	public function build(context:BuildContext):RenderNode {
		var rootStyle = new LayoutStyle();
		rootStyle.width = LayoutAxis.grow();
		rootStyle.height = LayoutAxis.grow();
		rootStyle.padding = new Insets(22.0, 18.0, 22.0, 18.0);
		rootStyle.childGap = 14.0;
		rootStyle.background = background;

		var content:View = switch (screen) {
			case "tracker": buildTracker();
			case "matrix": buildMatrix();
			case "diagnostics": buildDiagnostics();
			case _: buildSynth(context.viewportWidth);
		};
		return new Column("audio-lab-root", [
			new KeyedView("header", buildHeader()),
			new KeyedView("navigation", buildNavigation()),
			new KeyedView("content", content)
		], rootStyle).build(context);
	}

	function buildHeader():Row {
		var style = rowStyle(52.0);
		style.childAlignY = LayoutAlignmentY.Center;
		style.childGap = 14.0;
		style.height = LayoutAxis.fit();
		style.padding = new Insets(0.0, 12.0, 0.0, 12.0);
		style.wrapMode = LayoutWrapMode.Wrap;
		style.rowGap = 6.0;
		return new Row("header-row", [
			new KeyedView("title", new Text("NATIVEKIT AUDIO LAB", null, white, null, TextRole.Heading)),
			new KeyedView("subtitle", new Text("interactive DSP playground", null, muted, null, TextRole.Caption)),
			new KeyedView("header-spacer", spacer())
		], style);
	}

	function buildNavigation():Row {
		var names = [
			{key: "synth", label: "Synth Playground"},
			{key: "tracker", label: "Tracker"},
			{key: "matrix", label: "Modulation Matrix"},
			{key: "diagnostics", label: "Diagnostics"}
		];
		var children:Array<KeyedView> = [];
		for (item in names) {
			var navItem = item;
			var button = new Button(navItem.label, navButtonStyle(), function() {
				screen = navItem.key;
			}, "nav-" + navItem.key);
			button.variant = ButtonVariant.Navigation;
			button.selected = screen == navItem.key;
			children.push(new KeyedView(navItem.key, button));
		}
		var style = rowStyle(38.0);
		style.height = LayoutAxis.fit();
		style.wrapMode = LayoutWrapMode.Wrap;
		style.rowGap = 6.0;
		style.childGap = 6.0;
		return new Row("navigation-row", children, style);
	}

	function buildSynth(viewportWidth:Float):View {
		var compact = viewportWidth < 960.0;
		var presetButtons:Array<KeyedView> = [];
		for (id in AudioLabPreset.ids()) {
			var selected = id;
			var button = new Button(AudioLabPreset.label(selected), compactButtonStyle(), function() {
				lab.selectPreset(selected);
			}
			);
			button.selected = lab.preset == selected;
			presetButtons.push(new KeyedView(AudioLabPreset.label(selected), button));
		}
		var presetsStyle = new LayoutStyle();
		presetsStyle.width = LayoutAxis.grow();
		presetsStyle.height = LayoutAxis.fit();
		presetsStyle.wrapMode = LayoutWrapMode.Wrap;
		presetsStyle.rowGap = 6.0;
		presetsStyle.columnGap = 6.0;
		var presetPanel = new Column(
			"preset-panel",
			[
				new KeyedView("preset-title", label("PATCH BROWSER")),
				new KeyedView(
					"preset-buttons",
					new Row(
						"preset-buttons-row",
						presetButtons,
						presetsStyle
					)
				)
			],
			panelStyle()
		);

		var cutoff = new Slider(
			"filter-cutoff",
			"Filter cutoff",
			lab.filterCutoff,
			80.0,
			18000.0,
			10.0,
			function(value) lab.setFilterCutoff(value),
			sliderStyle()
		);
		var controlPanel = new Column(
			"synth-controls",
			[
				new KeyedView("section", title("SYNTH PLAYGROUND")),
				new KeyedView(
					"description",
					caption("Every control reaches the NativeKit DSP event path.")
				),
				new KeyedView(
					"presets",
					presetPanel
				),
				new KeyedView(
					"cutoff",
					labeledControl(
						"Filter cutoff",
						Std.int(lab.filterCutoff) + " Hz",
						cutoff
					)
				),
				new KeyedView(
					"playback-status",
					caption(lab.playbackStatus)
				),
				new KeyedView(
					"reverb-wet",
					labeledControl(
						"Room send",
						format(lab.reverbWet),
						new Slider(
							"reverb-wet",
							"Reverb wet",
							lab.reverbWet,
							0.0,
							1.0,
							0.01,
							function(value) lab.setReverbWet(value),
							sliderStyle()
						)
					)
				),
				new KeyedView(
					"reverb-decay",
					labeledControl(
						"Reverb decay",
						format(lab.reverbDecay) + " s",
						new Slider(
							"reverb-decay",
							"Reverb decay (s)",
							lab.reverbDecay,
							0.1,
							10.0,
							0.1,
							function(value) lab.setReverbDecay(value),
							sliderStyle()
						)
					)
				),
				new KeyedView(
					"compression-ratio",
					labeledControl(
						"Compression ratio",
						format(lab.compressionRatio) + ":1",
						new Slider(
							"compression-ratio",
							"Compression ratio",
							lab.compressionRatio,
							1.0,
							10.0,
							0.1,
							function(value) lab.setCompressionRatio(value),
							sliderStyle()
						)
					)
				),
				new KeyedView(
					"voices",
					label('voices ${lab.activeVoices}  •  events ${lab.eventCount}')
				)
			],
			panelStyle(compact ? null : 400.0)
		);

		var monitorPanel = new Column(
			"monitor-panel",
			[
				new KeyedView("monitor-title", title("SIGNAL MONITOR")),
				new KeyedView(
					"monitor-subtitle",
					caption('preset ${AudioLabPreset.label(lab.preset)}  •  48 kHz stereo')
				),
				new KeyedView(
					"scope",
					buildScope()
				),
				new KeyedView(
					"meter",
					buildMeter()
				),
				new KeyedView(
					"monitor-stats",
					label('peak ${format(lab.peak)}   rms ${format(lab.rms)}   render ${format(lab.renderMilliseconds)} ms')
				),
				new KeyedView(
					"routes-title",
					label("ACTIVE ROUTES")
				),
				new KeyedView(
					"routes",
					buildRouteSummary()
				)
			],
			panelStyle()
		);

		var keyboard = new Column(
			"keyboard-panel",
			[
				new KeyedView("piano-label", label("VIRTUAL PIANO")),
				new KeyedView(
					"piano-hint",
					caption("Click a note to audition the active patch.")
				),
				new KeyedView(
					"piano",
					buildPiano()
				)
			],
			panelStyle()
		);
		if (compact) {
			return new ScrollView(
				"synth-scroll",
				new Column(
					"synth-stack",
					[
						new KeyedView("controls", controlPanel),
						new KeyedView(
							"monitor",
							monitorPanel
						),
						new KeyedView(
							"keyboard",
							keyboard
						)
					],
					fitColumnStyle()
				),
				scrollStyle(),
				ScrollAxis.Vertical
			);
		}
		var bodyStyle = new LayoutStyle();
		bodyStyle.width = LayoutAxis.grow();
		bodyStyle.height = LayoutAxis.grow();
		bodyStyle.childGap = 14.0;
		var controlsStyle = scrollStyle();
		controlsStyle.width = LayoutAxis.fixed(400.0);
		monitorPanel.style.height = LayoutAxis.grow();
		var screenStyle = fitColumnStyle();
		screenStyle.height = LayoutAxis.grow();
		screenStyle.childGap = 14.0;
		return new Column(
			"synth-screen",
			[
				new KeyedView(
					"body",
					new Row(
						"synth-body",
						[
							new KeyedView(
								"controls",
								new ScrollView(
									"controls-scroll",
									controlPanel,
									controlsStyle,
									ScrollAxis.Vertical
								)
							),
							new KeyedView(
								"monitor",
								monitorPanel
							)
						],
						bodyStyle
					)
				),
				new KeyedView(
					"keyboard",
					keyboard
				)
			],
			screenStyle
		);
	}

	function scrollStyle():LayoutStyle {
		var style = new LayoutStyle();
		style.width = LayoutAxis.grow();
		style.height = LayoutAxis.grow();
		style.clipVertical = true;
		return style;
	}

	function labeledControl(name:String, value:String, control:View):Column {
		return new Column(
			"control-" + name,
			[
				new KeyedView("label", label(name + "  ·  " + value)),
				new KeyedView(
					"slider",
					control
				)
			],
			fitColumnStyle()
		);
	}

	function buildPiano():Row {
		var notes = [60, 61, 62, 63, 64, 65, 66, 67, 68, 69, 70, 71, 72];
		var keys:Array<KeyedView> = [];
		for (note in notes) {
			var selectedNote = note;
			var button = new Button(noteName(note), pianoStyle(), function() lab.noteOn(selectedNote), "piano-" + note);
			button.classes.push(isBlackKey(note) ? "black-key" : "white-key");
			keys.push(new KeyedView("key-" + note, button));
		}
		var style = new LayoutStyle();
		style.width = LayoutAxis.grow();
		style.height = LayoutAxis.fit();
		style.wrapMode = LayoutWrapMode.Wrap;
		style.rowGap = 4.0;
		style.childGap = 4.0;
		return new Row("piano-row", keys, style);
	}

	function buildScope():CanvasView {
		var style = new LayoutStyle();
		style.width = LayoutAxis.grow();
		style.height = LayoutAxis.fixed(190.0);
		return new CanvasView("oscilloscope", function(canvas:Canvas, geometry) {
			canvas.fillRoundedRect(new Rect(0.0, 0.0, geometry.width, geometry.height), 8.0,
				Color.rgba(0.025, 0.035, 0.055, 1.0));
			for (line in 1...4)
				canvas.fillRect(new Rect(0.0, geometry.height * line / 4.0,
					geometry.width, 1.0), Color.rgba(0.13, 0.19, 0.27, 0.65));
			var path = new PathBuilder();
			for (index in 0...lab.scope.length) {
				var x = geometry.width * index / (lab.scope.length - 1);
				var y = geometry.height * 0.5 - lab.scope[index] * geometry.height * 0.42;
				if (index == 0)
					path.moveTo(x, y);
				else
					path.lineTo(x, y);
			}
			canvas.strokeTransient(path.build(), accent, 2.0, LineCap.Round, LineJoin.Round);
		}, style, "Oscilloscope");
	}

	function buildMeter():CanvasView {
		var style = new LayoutStyle();
		style.width = LayoutAxis.grow();
		style.height = LayoutAxis.fixed(30.0);
		return new CanvasView("level-meter", function(canvas:Canvas, geometry) {
			canvas.fillRoundedRect(new Rect(0.0, 0.0, geometry.width, geometry.height), 5.0,
				Color.rgba(0.025, 0.035, 0.055, 1.0));
			var fill = Math.min(1.0, lab.peak);
			canvas.fillRoundedRect(new Rect(4.0, 7.0, Math.max(2.0, (geometry.width - 8.0) * fill),
				16.0), 3.0, fill > 0.85 ? Color.rgba(0.95, 0.34, 0.28, 1.0) : green);
		}, style, "Output level");
	}

	function buildRouteSummary():Column {
		var children:Array<KeyedView> = [];
		for (index in 0...AudioLabPreset.routeSummary(lab.preset).length)
			children.push(new KeyedView("route-" + index,
				new Text(AudioLabPreset.routeSummary(lab.preset)[index], null, muted, null, TextRole.Caption)));
		return new Column("route-summary", children, fitColumnStyle());
	}

	function buildTracker():View {
		var rows:Array<KeyedView> = [];
		var notes = [48, 48, 55, 60, 48, 48, 55, 62, 43, 43, 50, 55, 45, 45, 52, 57];
		for (row in 0...16) {
			var cells:Array<KeyedView> = [];
			var rowStyle = rowStyle(28.0);
			rowStyle.childGap = 4.0;
			cells.push(new KeyedView("row-number", new Text(StringTools.lpad(Std.string(row), "0", 2),
				fixedStyle(34.0, 28.0), row == lab.trackerStep && lab.trackerPlaying ? accent : muted)));
			for (channel in 0...4) {
				var note = channel == 0 ? notes[row] : channel == 1 ? notes[(row + 4) % notes.length] : -1;
				var trackerNote = note;
				var cell = new Button(note < 0 ? "---" : noteName(note), trackerCellStyle(), function() {
					if (trackerNote >= 0)
						lab.noteOn(trackerNote, 0.76);
				}, "tracker-cell-" + row + "-" + channel);
				cell.selected = lab.trackerPlaying && row == lab.trackerStep;
				cells.push(new KeyedView("channel-" + channel, cell));
			}
			rows.push(new KeyedView("row-" + row, new Row("tracker-row-" + row, cells, rowStyle)));
		}
		var contentStyle = new LayoutStyle();
		contentStyle.width = LayoutAxis.grow();
		contentStyle.height = LayoutAxis.fit();
		contentStyle.childGap = 3.0;
		var scrollStyle = new LayoutStyle();
		scrollStyle.width = LayoutAxis.grow();
		scrollStyle.height = LayoutAxis.grow();
		scrollStyle.clipVertical = true;
		var toolbar = new Row("tracker-toolbar", [
			new KeyedView("play", new Button(lab.trackerPlaying ? "Stop" : "Play 16-step pattern",
				compactButtonStyle(), function() lab.toggleTracker(), "tracker-play")),
			new KeyedView("tempo", label("120 BPM  •  16th-note clock  •  sample-accurate note events"))
		], rowStyle(38.0));
		return new Column("tracker-screen", [
			new KeyedView("title", title("TRACKER / SEQUENCER")),
			new KeyedView("description", caption("The grid drives the same DspEngine as the piano.")),
			new KeyedView("toolbar", toolbar),
			new KeyedView("grid", new ScrollView("tracker-scroll", new Column("tracker-grid", rows, contentStyle),
				scrollStyle, ScrollAxis.Vertical))
		], growColumnStyle());
	}

	function buildMatrix():View {
		var routeRows:Array<KeyedView> = [];
		var routes = AudioLabPreset.routeSummary(lab.preset);
		for (index in 0...routes.length) {
			var routeStyle = rowStyle(44.0);
			routeStyle.background = panelRaised;
			routeStyle.padding = new Insets(10.0, 10.0, 10.0, 10.0);
			routeRows.push(new KeyedView("matrix-route-" + index,
				new Row("matrix-route-content", [new KeyedView("route", new Text(routes[index], null, white,
					null, TextRole.Label))], routeStyle)));
		}
		return new Column("matrix-screen", [
			new KeyedView("title", title("MODULATION MATRIX")),
			new KeyedView("description", caption("Typed routes below are materialized in the active immutable DSP patch.")),
			new KeyedView("routes", new Column("matrix-routes", routeRows, fitColumnStyle())),
			new KeyedView("hint", caption("Switch presets in Synth Playground to inspect different oscillator, LFO, envelope, and FM/PM routes."))
		], growColumnStyle());
	}

	function buildDiagnostics():View {
		return new Column("diagnostics-screen", [
			new KeyedView("title", title("DIAGNOSTICS")),
			new KeyedView("description", caption("Live values collected around each standalone DSP render block.")),
			new KeyedView("card", new Column("diagnostics-card", [
				new KeyedView("voices", diagnostic("ACTIVE VOICES", Std.string(lab.activeVoices))),
			new KeyedView("events", diagnostic("EVENTS TOTAL", Std.string(lab.eventCount))),
				new KeyedView("frame", diagnostic("CURRENT FRAME", Std.string(lab.frame))),
				new KeyedView("timing", diagnostic("CPU RENDER TIME", format(lab.renderMilliseconds) + " ms")),
				new KeyedView("peak", diagnostic("OUTPUT PEAK", format(lab.peak))),
				new KeyedView("rms", diagnostic("OUTPUT RMS", format(lab.rms))),
				new KeyedView("rate", diagnostic("SAMPLE RATE", "48000 Hz / 256-frame blocks")),
				new KeyedView("status", new Text("Renderer status: ACTIVE  •  event path: SAMPLE-ACCURATE",
					null, green, null, TextRole.Label))
			], panelStyle()))
		], growColumnStyle());
	}

	function diagnostic(name:String, value:String):Row {
		var style = rowStyle(34.0);
		style.childGap = 12.0;
		return new Row("diagnostic-" + name, [
			new KeyedView("name", new Text(name, fixedStyle(190.0, 30.0), muted, null, TextRole.Caption)),
			new KeyedView("value", new Text(value, null, white, null, TextRole.Label))
		], style);
	}

	function title(value:String):Text
		return new Text(value, null, white, null, TextRole.Heading);

	function label(value:String):Text
		return new Text(value, null, white, null, TextRole.Label);

	function caption(value:String):Text
		return new Text(value, null, muted, null, TextRole.Caption);

	function panelStyle(?width:Float):LayoutStyle {
		var style = new LayoutStyle();
		style.width = width == null ? LayoutAxis.grow() : LayoutAxis.fixed(width);
		style.height = LayoutAxis.fit();
		style.padding = new Insets(16.0, 16.0, 16.0, 16.0);
		style.childGap = 10.0;
		style.background = panel;
		style.radiusTopLeft = style.radiusTopRight = style.radiusBottomLeft = style.radiusBottomRight = 10.0;
		return style;
	}

	function growColumnStyle():LayoutStyle {
		var style = panelStyle();
		style.height = LayoutAxis.grow();
		return style;
	}

	function fitColumnStyle():LayoutStyle {
		var style = new LayoutStyle();
		style.width = LayoutAxis.grow();
		style.height = LayoutAxis.fit();
		style.childGap = 6.0;
		return style;
	}

	function rowStyle(height:Float):LayoutStyle {
		var style = new LayoutStyle();
		style.width = LayoutAxis.grow();
		style.height = LayoutAxis.fixed(height);
		return style;
	}

	function fixedStyle(width:Float, height:Float):LayoutStyle {
		var style = new LayoutStyle();
		style.width = LayoutAxis.fixed(width);
		style.height = LayoutAxis.fixed(height);
		return style;
	}

	function navButtonStyle():LayoutStyle
		return fixedStyle(180.0, 36.0);

	function compactButtonStyle():LayoutStyle
		return fixedStyle(160.0, 30.0);

	function trackerCellStyle():LayoutStyle
		return fixedStyle(112.0, 26.0);

	function pianoStyle():LayoutStyle
		return fixedStyle(48.0, 48.0);

	function sliderStyle():LayoutStyle
		return rowStyle(34.0);

	function spacer():Text {
		var style = new LayoutStyle();
		style.width = LayoutAxis.grow();
		return new Text("", style);
	}

	function format(value:Float):String
		return Std.string(Math.round(value * 100.0) / 100.0);

	static function noteName(note:Int):String {
		var names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"];
		var octave = Std.int(note / 12) - 1;
		return names[note % 12] + octave;
	}

	static function isBlackKey(note:Int):Bool
		return switch (note % 12) {
			case 1 | 3 | 6 | 8 | 10: true;
			case _: false;
		};
}
