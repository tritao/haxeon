@vs triangle_vs
layout(location=0) in vec2 position;
layout(location=1) in vec3 rgb;
out vec3 color;

void main() {
    gl_Position = vec4(position, 0.0, 1.0);
    color = rgb;
}
@end

@fs triangle_fs
in vec3 color;
out vec4 pixel;

void main() {
    pixel = vec4(color, 1.0);
}
@end

@program triangle triangle_vs triangle_fs
