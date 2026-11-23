#version 330

in vec3 color;
out vec4 pixel;

void main() {
    pixel = vec4(color, 1.0);
}
