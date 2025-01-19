@group(2) @binding(2) var<storage, read> material_pixels: array<u32>;

struct FragmentIn {
    @location(0) uv: vec2f,
    @location(1) @interpolate(flat) material_index: u32,
}

@fragment fn main(in: FragmentIn) -> @location(0) vec4f {
    let uv = in.uv;
    let material_index = in.material_index;

    let uv_int = vec2u(uv * 8);

    let colour_unorm = material_pixels[material_index * 8 * 8 + uv_int.y * 8 + uv_int.x];
    let colour = unpack4x8unorm(colour_unorm).rgb;

    return vec4f((colour), 1);
}