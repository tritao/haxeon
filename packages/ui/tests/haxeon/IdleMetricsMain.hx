import haxeon.reactive.Signal;
import haxeon.ui.FontCollection;
import haxeon.ui.LayoutFrame;
import haxeon.ui.core.UiContext;
import haxeon.ui.core.View;
import haxeon.ui.widgets.text.Text;

/** An unobserved idle frame allocates nothing; observed metrics stay independent snapshots. */
class IdleMetricsMain {
  static function main():Int {
    var fontPath = Sys.getEnv("NKUI_TEST_FONT_PATH");
    if (fontPath == null || Sys.args().length != 1) return 1;
    var fonts = FontCollection.create();
    fonts.add(fontPath);
    var ui = new UiContext(null, fonts), frame = new LayoutFrame(300, 80);
    ui.verifyRetentionEvery = 1;
    var source = new Signal<String>("one");
    function build():View return new Text(source.value);
    ui.submitCached(build, frame, "test");
    var first = ui.frameMetrics;
    if (first == null) return 2;
    var firstNumber = first.frameNumber;
    ui.submitCached(build, frame, "test");
    hl.Gc.censusStart(0);
    var result = ui.submitCached(build, frame, "test");
    hl.Gc.censusStop();
    hl.Gc.censusDump(Sys.args()[0]);
    if (result.layout.text != "one") return 3;
    var idle = ui.frameMetrics;
    if (idle == null || !idle.reusedSubmission || idle.nativeLayoutSubmitted || !idle.nativeLayoutReused
        || idle.frameNumber != firstNumber + 2 || idle.nodeCount != first.nodeCount || first.frameNumber != firstNumber) return 4;
    source.value = "two";
    var changed = ui.submitCached(build, frame, "test");
    var current = ui.frameMetrics;
    if (changed.layout.text != "two" || current == null || current.reusedSubmission || first.frameNumber != firstNumber) return 5;
    ui.dispose(); fonts.dispose();
    return 42;
  }
}
