import pages.ControlsPage;
import pages.DecorationsPage;
import pages.EffectsPage;
import pages.GesturesPage;
import pages.GraphicsPage;
import pages.LayoutPage;
import pages.ListsPage;
import pages.OverlaysPage;
import pages.OverviewPage;
import pages.TextPage;
import pages.WebViewPage;
import pages.WindowChromePage;

/** Canonical inventory for the Haxeon UI Explorer's pages and navigation. */
class ExplorerCatalog {
	static final pageList:Array<ExplorerPage> = [new ExplorerPage("overview", "Overview", "start",
		"Haxeon framework and runtime overview",
		[
			"welcome",
			"haxeon",
			"native",
			"runtime"
		],
		(explorer, items) -> {
			OverviewPage.build(explorer, items);
		}),
			new ExplorerPage("controls", "Controls", "components", "Interactive control states",
			[
				"button",
				"checkbox",
				"toggle",
				"radio",
				"select",
				"slider",
				"progress",
				"spinner",
				"loading",
				"indeterminate"
			],
			(explorer, items) -> {
		ControlsPage.build(explorer, items);
	}),
		new ExplorerPage("text", "Text & Input", "components", "Text editing and platform input",
		[
			"textfield",
			"textarea",
			"ime",
			"selection",
			"clipboard",
			"multilingual"
		],
		(explorer, items) -> {
		TextPage.build(explorer, items);
	}),
		new ExplorerPage("layout", "Layout", "components", "Composable layout primitives",
		[
			"row",
			"column",
			"padding",
			"align",
			"stack",
			"clip",
			"z-order"
		],
		(explorer, items) -> {
		LayoutPage.build(explorer, items);
	}),
		new ExplorerPage("lists", "Scrolling & Data", "components", "Scrolling and fixed-row virtualization",
		[
			"scrollview",
			"virtuallist",
			"virtualization",
			"10000 rows"
		],
		(explorer, items) -> {
		ListsPage.build(explorer, items);
	}),
		new ExplorerPage("overlays", "Navigation & Overlays", "components", "Tabs and floating UI",
		[
			"tabs",
			"popup",
			"menu",
			"tooltip",
			"dialog",
			"overlay"
		],
		(explorer, items) -> {
		OverlaysPage.build(explorer, items);
	}, "Overlays"),
		new ExplorerPage("gestures", "Gestures & Motion", "components", "Gesture arbitration and animation",
		[
			"tap",
			"double tap",
			"long press",
			"drag",
			"tween",
			"spring",
			"animation"
		],
		(explorer, items) -> {
		GesturesPage.build(explorer, items);
	}),
		new ExplorerPage("webview", "WebView", "components", "Embedded platform web content",
		[
			"web",
			"browser",
			"html",
			"javascript",
			"native view"
		],
		(explorer, items) -> {
		WebViewPage.build(explorer, items);
	}),
		new ExplorerPage("graphics-paths", "Paths & Paint", "graphics", "Vector geometry, strokes and compositing",
		[
			"bezier",
			"path",
			"stroke",
			"join",
			"paint",
			"alpha",
			"blend"
		],
		(explorer, items) -> {
		GraphicsPage.buildPaths(explorer, items);
	}),
		new ExplorerPage("graphics-gradients", "Gradients", "graphics",
		"Linear gradients, color stops and transparency",
		[
			"gradient",
			"linear",
			"color stops",
			"alpha",
			"interpolation"
		],
		(explorer, items) -> {
		GraphicsPage.buildGradients(explorer, items);
	}),
		new ExplorerPage("graphics-decorations", "Decorations", "graphics",
		"Stylesheet-driven backgrounds, borders, images and shadows",
		[
			"decoration",
			"background",
			"gradient",
			"border",
			"shadow",
			"image",
			"nine slice",
			"style"
		],
		(explorer, items) -> {
		DecorationsPage.build(explorer, items);
	}),
		new ExplorerPage("graphics-effects", "Effects", "graphics",
		"Blur, color effects, masks and backdrop composition",
		[
			"effects",
			"blur",
			"brightness",
			"contrast",
			"saturate",
			"hue",
			"shadow",
			"mask",
			"backdrop"
		],
		(explorer, items) -> {
		EffectsPage.build(explorer, items);
	}),
		new ExplorerPage("graphics-3d", "3D Views", "graphics", "Perspective meshes and composited native surfaces",
		[
			"3d",
			"mesh",
			"cube",
			"perspective",
			"depth",
			"surface",
			"offscreen"
		],
		(explorer, items) -> {
		GraphicsPage.build3d(explorer, items);
	}),
		new ExplorerPage("graphics-text", "Text Shaping", "graphics", "Multilingual shaping and text geometry",
		[
			"font",
			"glyph",
			"bidi",
			"caret",
			"selection",
			"arabic",
			"hebrew",
			"japanese",
			"emoji"
		],
		(explorer, items) -> {
		GraphicsPage.buildText(explorer, items);
	}),
		new ExplorerPage("graphics-images", "Images & Layers", "graphics", "Clipping, opacity and layered composition",
		[
			"image",
			"clip",
			"layer",
			"opacity",
			"nine slice",
			"composite"
		],
		(explorer, items) -> {
		GraphicsPage.buildImages(explorer, items);
	}),
		new ExplorerPage("graphics-rendering", "Rendering", "graphics",
		"Retained rendering and frame performance diagnostics",
		[
			"display list",
			"retained",
			"renderer",
			"offscreen",
			"surface",
			"cube",
			"performance"
		],
		(explorer, items) -> {
		GraphicsPage.buildRendering(explorer, items);
	}),
		new ExplorerPage("window-chrome", "Window Chrome", "developer", "Custom native window decorations",
		[
			"window",
			"chrome",
			"borderless",
			"drag",
			"resize",
			"decorations",
			"multi-window"
		],
		(explorer, items) -> {
		WindowChromePage.build(explorer, items);
	})];

	public static function all():Array<ExplorerPage>
		return pageList;

	public static function find(id:String):Null<ExplorerPage> {
		for (page in pageList)
			if (page.id == id)
				return page;
		return null;
	}

	public static function matches(page:ExplorerPage, needle:String):Bool {
		if (UiExplorer.containsInsensitive(page.title, needle)
			|| UiExplorer.containsInsensitive(page.description, needle))
			return true;
		for (keyword in page.keywords)
			if (UiExplorer.containsInsensitive(keyword, needle))
				return true;
		return false;
	}

	public static function groupTitle(group:String):String {
		return switch group {
			case "start": "START HERE";
			case "components": "COMPONENTS";
			case "graphics": "GRAPHICS";
			case "developer": "DEVELOPER TOOLS";
			default: group;
		};
	}
}
