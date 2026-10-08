#version 460 core

uniform Info {
    mat4 mvp;
    vec4 color;
} info;

in vec3 position;
out vec4 vColor;
out vec2 vUv;

void main() {
    gl_Position = info.mvp * vec4(position, 1.0);
    vColor = info.color;
    vUv = position.xy * 0.5 + 0.5;
}
