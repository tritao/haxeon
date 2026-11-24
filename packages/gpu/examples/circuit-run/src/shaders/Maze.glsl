@vs maze_vs
layout(location=0) in vec2 position;
layout(location=1) in vec3 rgb;
out vec3 color;

void main() {
    color = rgb;
    gl_Position = vec4(position, 0.0, 1.0);
}
@end

@fs maze_fs
in vec3 color;
layout(location=0) out vec4 pixel;

void main() {
    pixel = vec4(color, 1.0);
}
@end

@program maze maze_vs maze_fs
