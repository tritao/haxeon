import haxeon.ui.LayoutAxis;
import haxeon.ui.LayoutStyle;
import haxeon.ui.LayoutSizing;

/** Capture defaults during module initialization, before application startup. */
class LayoutDefaultsTests {
  static final earlyStyle=new LayoutStyle();
  static final earlyGrow=LayoutAxis.grow();
  static function check(value:Bool,message:String):Void {if(!value) throw message;}
  static function main():Void {
    check(earlyStyle.width!=null && earlyStyle.height!=null && earlyGrow!=null,"Early styles retained null axes");
    check(earlyStyle.width.sizing==LayoutSizing.Fit && earlyGrow.sizing==LayoutSizing.Grow,"Early policy differs from requested sizing");
    check(LayoutAxis.fit()==earlyStyle.width && LayoutAxis.grow()==earlyGrow,"Default policies are not shared immutable instances");
    var custom=LayoutAxis.grow(4,100,2);
    check(custom!=earlyGrow && custom.min==4 && custom.max==100 && custom.growWeight==2,"Custom axis lost its bounds/weight");
    Sys.println("Layout defaults passed: initialization, shared defaults and explicit bounds");
  }
}
