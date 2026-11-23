#version 300 es
precision highp float;

in vec3 color;
out vec4 pixel;

void main() {
    pixel = vec4(color, 1.0);
}
