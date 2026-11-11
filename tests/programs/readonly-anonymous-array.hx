typedef ReadPoint = { final x:Int; }

function sum(points:Array<ReadPoint>):Int {
  var value = points[0].x;
  points[0] = {x: value + 1};
  return value;
}

function get(point:ReadPoint):Int return point.x;

function main():Int {
  var values = [for (i in 40...41) {x: i}];
  var initial = get(values[0]);
  var result = sum(values);
  values[0].x++;
  return initial == 40 && result == 40 && values[0].x == 42 ? 42 : 1;
}
