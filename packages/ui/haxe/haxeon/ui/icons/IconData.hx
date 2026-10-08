package haxeon.ui.icons;

import haxeon.ui.Path;
import haxeon.ui.PathBuilder;

/** Generated 24×24 vector paths derived from the vendored Lucide SVG assets. */
class IconData {
	public static function build(name:IconName):Path {
		return switch name {
			case IconName.Settings: settings();
			case IconName.WindowMinimize: new PathBuilder().moveTo(5, 12).lineTo(19, 12).build();
			case IconName.WindowMaximize: new PathBuilder().moveTo(5, 5).lineTo(19, 5).lineTo(19, 19).lineTo(5, 19).lineTo(5, 5).build();
			case IconName.WindowRestore: new PathBuilder().moveTo(8, 8).lineTo(8, 4).lineTo(20, 4).lineTo(20, 16).lineTo(16, 16)
				.moveTo(4, 8).lineTo(16, 8).lineTo(16, 20).lineTo(4, 20).lineTo(4, 8).build();
			case IconName.Check: new PathBuilder().moveTo(4, 12).lineTo(9, 17).lineTo(20, 6).build();
			case IconName.Remote: new PathBuilder().moveTo(15, 3).lineTo(21, 9).lineTo(15, 15)
				.moveTo(9, 9).lineTo(3, 15).lineTo(9, 21).build();
			case IconName.Bell: new PathBuilder().moveTo(18, 8)
				.cubicTo(18, 4.69, 15.31, 2, 12, 2).cubicTo(8.69, 2, 6, 4.69, 6, 8)
				.cubicTo(6, 15, 3, 15, 3, 17).lineTo(21, 17).cubicTo(21, 15, 18, 15, 18, 8)
				.moveTo(10, 21).cubicTo(11, 22.33, 13, 22.33, 14, 21).build();
			case IconName.AlertTriangle: new PathBuilder().moveTo(12, 3).lineTo(22, 21).lineTo(2, 21).lineTo(12, 3)
				.moveTo(12, 9).lineTo(12, 14).moveTo(12, 17).lineTo(12, 17.2).build();
			case IconName.ErrorCircle: new PathBuilder().moveTo(22, 12).cubicTo(22, 17.52, 17.52, 22, 12, 22)
				.cubicTo(6.48, 22, 2, 17.52, 2, 12).cubicTo(2, 6.48, 6.48, 2, 12, 2).cubicTo(17.52, 2, 22, 6.48, 22, 12)
				.moveTo(8, 8).lineTo(16, 16).moveTo(16, 8).lineTo(8, 16).build();
			case IconName.InfoCircle: new PathBuilder().moveTo(22, 12).cubicTo(22, 17.52, 17.52, 22, 12, 22)
				.cubicTo(6.48, 22, 2, 17.52, 2, 12).cubicTo(2, 6.48, 6.48, 2, 12, 2).cubicTo(17.52, 2, 22, 6.48, 22, 12)
				.moveTo(12, 11).lineTo(12, 17).moveTo(12, 7).lineTo(12, 7.2).build();
			case IconName.Search: search();
			case IconName.Close: close();
			case IconName.Sun: sun();
			case IconName.Moon: moon();
			case IconName.Inspect: inspect();
			case IconName.Hierarchy: hierarchy();
			case IconName.Building: building();
			case IconName.Grid: grid();
			case IconName.Cube: cube();
			case IconName.Sliders: sliders();
			case IconName.Radar: radar();
			case IconName.Terminal: terminal();
			case IconName.Activity: activity();
			case IconName.Magnet: magnet();
			case IconName.Play: new PathBuilder().moveTo(7, 4).lineTo(19, 12).lineTo(7, 20).lineTo(7, 4).build();
			case IconName.Pause: new PathBuilder().moveTo(8, 5).lineTo(8, 19).moveTo(16, 5).lineTo(16, 19).build();
			case IconName.StepForward: new PathBuilder().moveTo(6, 4).lineTo(16, 12).lineTo(6, 20).lineTo(6, 4)
				.moveTo(19, 5).lineTo(19, 19).build();
			case IconName.Reset: new PathBuilder().moveTo(4, 5).lineTo(4, 10).lineTo(9, 10)
				.moveTo(4, 10).cubicTo(6, 6, 9, 4, 13, 4).cubicTo(18, 4, 21, 8, 21, 12)
				.cubicTo(21, 17, 17, 20, 12, 20).cubicTo(9, 20, 6, 18, 5, 15).build();
			case IconName.Stop: new PathBuilder().moveTo(6, 6).lineTo(18, 6).lineTo(18, 18).lineTo(6, 18).lineTo(6, 6).build();
			case IconName.ChevronDown: new PathBuilder().moveTo(6, 9).lineTo(12, 15).lineTo(18, 9).build();
			case IconName.ChevronRight: new PathBuilder().moveTo(9, 6).lineTo(15, 12).lineTo(9, 18).build();
			case IconName.Plus: new PathBuilder().moveTo(12, 5).lineTo(12, 19)
				.moveTo(5, 12).lineTo(19, 12).build();
			case IconName.Copy: new PathBuilder().moveTo(8, 8).lineTo(19, 8).lineTo(19, 19)
				.lineTo(8, 19).lineTo(8, 8).moveTo(5, 15).lineTo(5, 5).lineTo(15, 5).build();
			case IconName.Trash: new PathBuilder().moveTo(4, 7).lineTo(20, 7)
				.moveTo(9, 7).lineTo(9, 4).lineTo(15, 4).lineTo(15, 7)
				.moveTo(6, 7).lineTo(7, 20).lineTo(17, 20).lineTo(18, 7)
				.moveTo(10, 10).lineTo(10, 17).moveTo(14, 10).lineTo(14, 17).build();
			case IconName.NewFile: new PathBuilder().moveTo(13, 3).lineTo(5, 3).lineTo(5, 21)
				.lineTo(19, 21).lineTo(19, 9).lineTo(13, 3).lineTo(13, 9).lineTo(19, 9)
				.moveTo(12, 13).lineTo(12, 19).moveTo(9, 16).lineTo(15, 16).build();
			case IconName.FolderClosed: new PathBuilder().moveTo(3, 7).lineTo(3, 5)
				.lineTo(10, 5).lineTo(12, 7).lineTo(21, 7).lineTo(21, 20)
				.lineTo(3, 20).lineTo(3, 7).build();
			case IconName.FolderOpen: new PathBuilder().moveTo(3, 7).lineTo(3, 5)
				.lineTo(10, 5).lineTo(12, 7).lineTo(21, 7).lineTo(21, 10)
				.moveTo(3, 11).lineTo(22, 11).lineTo(19, 20).lineTo(5, 20).lineTo(3, 11).build();
			case IconName.Save: new PathBuilder().moveTo(4, 3).lineTo(18, 3).lineTo(21, 6)
				.lineTo(21, 21).lineTo(3, 21).lineTo(3, 3).lineTo(4, 3)
				.moveTo(7, 3).lineTo(7, 9).lineTo(17, 9).lineTo(17, 3)
				.moveTo(7, 21).lineTo(7, 14).lineTo(17, 14).lineTo(17, 21).build();
			case IconName.Undo: new PathBuilder().moveTo(9, 7).lineTo(4, 12).lineTo(9, 17)
				.moveTo(4, 12).lineTo(14, 12).cubicTo(18, 12, 20, 14, 20, 18).build();
			case IconName.Redo: new PathBuilder().moveTo(15, 7).lineTo(20, 12).lineTo(15, 17)
				.moveTo(20, 12).lineTo(10, 12).cubicTo(6, 12, 4, 14, 4, 18).build();
			case _: throw "Unsupported icon name";
		};
	}

	static function settings():Path {
		var path = new PathBuilder();
		for (index in 0...32) {
			var angle = -Math.PI / 2 + index * Math.PI / 16;
			var radius = index % 4 == 0 || index % 4 == 3 ? 8 : 10;
			var x = 12 + Math.cos(angle) * radius, y = 12 + Math.sin(angle) * radius;
			if (index == 0) path.moveTo(x, y); else path.lineTo(x, y);
		}
		path.close();
		path.moveTo(15, 12).cubicTo(15, 13.657, 13.657, 15, 12, 15)
			.cubicTo(10.343, 15, 9, 13.657, 9, 12).cubicTo(9, 10.343, 10.343, 9, 12, 9)
			.cubicTo(13.657, 9, 15, 10.343, 15, 12);
		return path.build();
	}

	static function magnet():Path
		return new PathBuilder()
			.moveTo(4.0, 4.0).lineTo(4.0, 13.0)
			.cubicTo(4.0, 18.0, 7.5, 21.0, 12.0, 21.0)
			.cubicTo(16.5, 21.0, 20.0, 18.0, 20.0, 13.0)
			.lineTo(20.0, 4.0).lineTo(15.0, 4.0).lineTo(15.0, 13.0)
			.cubicTo(15.0, 15.0, 13.8, 16.0, 12.0, 16.0)
			.cubicTo(10.2, 16.0, 9.0, 15.0, 9.0, 13.0)
			.lineTo(9.0, 4.0).lineTo(4.0, 4.0)
			.moveTo(4.0, 8.0).lineTo(9.0, 8.0)
			.moveTo(15.0, 8.0).lineTo(20.0, 8.0).build();

	static function search():Path {
		var k = 4.4182779984;
		return new PathBuilder()
			.moveTo(21.0, 21.0).lineTo(16.66, 16.66)
			.moveTo(19.0, 11.0)
			.cubicTo(19.0, 11.0 + k, 11.0 + k, 19.0, 11.0, 19.0)
			.cubicTo(11.0 - k, 19.0, 3.0, 11.0 + k, 3.0, 11.0)
			.cubicTo(3.0, 11.0 - k, 11.0 - k, 3.0, 11.0, 3.0)
			.cubicTo(11.0 + k, 3.0, 19.0, 11.0 - k, 19.0, 11.0)
			.build();
	}

	static function close():Path
		return new PathBuilder().moveTo(18.0, 6.0).lineTo(6.0, 18.0)
			.moveTo(6.0, 6.0).lineTo(18.0, 18.0).build();

	static function sun():Path {
		var k = 2.2091389992;
		return new PathBuilder()
			.moveTo(16.0, 12.0)
			.cubicTo(16.0, 12.0 + k, 12.0 + k, 16.0, 12.0, 16.0)
			.cubicTo(12.0 - k, 16.0, 8.0, 12.0 + k, 8.0, 12.0)
			.cubicTo(8.0, 12.0 - k, 12.0 - k, 8.0, 12.0, 8.0)
			.cubicTo(12.0 + k, 8.0, 16.0, 12.0 - k, 16.0, 12.0)
			.moveTo(12.0, 2.0).lineTo(12.0, 4.0)
			.moveTo(12.0, 20.0).lineTo(12.0, 22.0)
			.moveTo(4.93, 4.93).lineTo(6.34, 6.34)
			.moveTo(17.66, 17.66).lineTo(19.07, 19.07)
			.moveTo(2.0, 12.0).lineTo(4.0, 12.0)
			.moveTo(20.0, 12.0).lineTo(22.0, 12.0)
			.moveTo(4.93, 19.07).lineTo(6.34, 17.66)
			.moveTo(17.66, 6.34).lineTo(19.07, 4.93).build();
	}

	static function moon():Path
		return new PathBuilder()
			.moveTo(21.0, 12.79)
			.cubicTo(18.7, 14.05, 15.9, 13.95, 13.72, 12.35)
			.cubicTo(11.54, 10.75, 10.45, 8.14, 10.9, 5.55)
			.cubicTo(11.08, 4.5, 11.45, 3.5, 12.0, 2.62)
			.cubicTo(7.15, 2.8, 3.25, 6.78, 3.25, 11.68)
			.cubicTo(3.25, 16.7, 7.32, 20.77, 12.34, 20.77)
			.cubicTo(16.0, 20.77, 19.3, 18.57, 20.72, 15.2)
			.cubicTo(21.05, 14.42, 21.15, 13.6, 21.0, 12.79).build();

	static function inspect():Path
		return new PathBuilder()
			.moveTo(9.0, 3.0).lineTo(5.0, 3.0).lineTo(5.0, 7.0)
			.moveTo(15.0, 3.0).lineTo(19.0, 3.0).lineTo(19.0, 7.0)
			.moveTo(9.0, 21.0).lineTo(5.0, 21.0).lineTo(5.0, 17.0)
			.moveTo(15.0, 21.0).lineTo(19.0, 21.0).lineTo(19.0, 17.0)
			.moveTo(12.0, 8.0).lineTo(12.0, 16.0)
			.moveTo(8.0, 12.0).lineTo(16.0, 12.0).build();

	static function hierarchy():Path
		return new PathBuilder()
			.moveTo(12.0, 4.0).lineTo(12.0, 9.0).moveTo(5.0, 9.0).lineTo(19.0, 9.0)
			.moveTo(5.0, 9.0).lineTo(5.0, 13.0).moveTo(12.0, 9.0).lineTo(12.0, 13.0)
			.moveTo(19.0, 9.0).lineTo(19.0, 13.0)
			.moveTo(2.0, 13.0).lineTo(8.0, 13.0).lineTo(8.0, 19.0).lineTo(2.0, 19.0).lineTo(2.0, 13.0)
			.moveTo(9.0, 13.0).lineTo(15.0, 13.0).lineTo(15.0, 19.0).lineTo(9.0, 19.0).lineTo(9.0, 13.0)
			.moveTo(16.0, 13.0).lineTo(22.0, 13.0).lineTo(22.0, 19.0).lineTo(16.0, 19.0).lineTo(16.0, 13.0).build();

	static function building():Path
		return new PathBuilder()
			.moveTo(3.0, 21.0).lineTo(3.0, 8.0).lineTo(12.0, 3.0).lineTo(21.0, 8.0).lineTo(21.0, 21.0)
			.moveTo(2.0, 21.0).lineTo(22.0, 21.0).moveTo(8.0, 21.0).lineTo(8.0, 12.0)
			.lineTo(16.0, 12.0).lineTo(16.0, 21.0).moveTo(6.0, 9.0).lineTo(6.0, 10.0)
			.moveTo(12.0, 7.0).lineTo(12.0, 9.0).moveTo(18.0, 9.0).lineTo(18.0, 10.0).build();

	static function grid():Path
		return new PathBuilder()
			.moveTo(3.0, 3.0).lineTo(10.0, 3.0).lineTo(10.0, 10.0).lineTo(3.0, 10.0).lineTo(3.0, 3.0)
			.moveTo(14.0, 3.0).lineTo(21.0, 3.0).lineTo(21.0, 10.0).lineTo(14.0, 10.0).lineTo(14.0, 3.0)
			.moveTo(3.0, 14.0).lineTo(10.0, 14.0).lineTo(10.0, 21.0).lineTo(3.0, 21.0).lineTo(3.0, 14.0)
			.moveTo(14.0, 14.0).lineTo(21.0, 14.0).lineTo(21.0, 21.0).lineTo(14.0, 21.0).lineTo(14.0, 14.0).build();

	static function cube():Path
		return new PathBuilder()
			.moveTo(12.0, 3.0).lineTo(21.0, 8.0).lineTo(21.0, 17.0).lineTo(12.0, 22.0)
			.lineTo(3.0, 17.0).lineTo(3.0, 8.0).lineTo(12.0, 3.0)
			.moveTo(3.0, 8.0).lineTo(12.0, 13.0).lineTo(21.0, 8.0)
			.moveTo(12.0, 13.0).lineTo(12.0, 22.0).moveTo(12.0, 3.0).lineTo(12.0, 13.0).build();

	static function sliders():Path
		return new PathBuilder()
			.moveTo(4.0, 6.0).lineTo(20.0, 6.0).moveTo(4.0, 12.0).lineTo(20.0, 12.0)
			.moveTo(4.0, 18.0).lineTo(20.0, 18.0).moveTo(9.0, 3.0).lineTo(9.0, 9.0)
			.moveTo(15.0, 9.0).lineTo(15.0, 15.0).moveTo(7.0, 15.0).lineTo(7.0, 21.0).build();

	static function radar():Path
		return new PathBuilder()
			.moveTo(12.0, 12.0).lineTo(19.0, 5.0).moveTo(12.0, 12.0).lineTo(21.0, 12.0)
			.moveTo(12.0, 12.0).lineTo(12.0, 3.0)
			.moveTo(5.64, 5.64).cubicTo(2.13, 9.15, 2.13, 14.85, 5.64, 18.36)
			.moveTo(18.36, 5.64).cubicTo(21.87, 9.15, 21.87, 14.85, 18.36, 18.36)
			.moveTo(8.46, 8.46).cubicTo(6.51, 10.41, 6.51, 13.59, 8.46, 15.54)
			.moveTo(12.0, 12.0).lineTo(12.0, 12.1).build();

	static function terminal():Path
		return new PathBuilder()
			.moveTo(3.0, 4.0).lineTo(21.0, 4.0).lineTo(21.0, 20.0).lineTo(3.0, 20.0).lineTo(3.0, 4.0)
			.moveTo(7.0, 9.0).lineTo(10.0, 12.0).lineTo(7.0, 15.0)
			.moveTo(12.0, 15.0).lineTo(17.0, 15.0).build();

	static function activity():Path
		return new PathBuilder()
			.moveTo(3.0, 12.0).lineTo(7.0, 12.0).lineTo(10.0, 5.0).lineTo(14.0, 19.0)
			.lineTo(17.0, 12.0).lineTo(21.0, 12.0).build();
}
