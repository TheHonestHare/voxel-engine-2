@group(0) @binding(0) var<uniform> perspective_mat: mat4x4<f32>;
@group(1) @binding(0) var<uniform> camera_transform_mat: mat4x4<f32>;
@group(2) @binding(0) var<storage, read> faces: array<u32, max_face_count>;
@group(2) @binding(1) var<storage, read> chunk_pos: vec3u;

// pub const Face = packed struct(u32) {
//     pub const Direction = enum(u3) {
//         east = 0b000,
//         west = 0b001,
//         south = 0b010,
//         north = 0b011,
//         bottom = 0b100,
//         top = 0b101,
//     };
//     x: u4,
//     y: u4,
//     z: u4,
//     face: Direction,
//     __padding: u1,            
//     material: u16,
// };

const west_face_vertices = array<vec3<bool>, 4>(
    vec3<bool>(false, true, true),
    vec3<bool>(false, false, true),
    vec3<bool>(false, true, false),
    vec3<bool>(false, false, false),
);

const east_face_vertices = array<vec3<bool>, 4>(
    vec3<bool>(true, true, false),
    vec3<bool>(true, false, false),
    vec3<bool>(true, true, true),
    vec3<bool>(true, false, true),
);

const south_face_vertices = array<vec3<bool>, 4>(
    vec3<bool>(false, true, false),
    vec3<bool>(false, false, false),
    vec3<bool>(true, true, false),
    vec3<bool>(true, false, false),
);

const north_face_vertices = array<vec3<bool>, 4>(
    vec3<bool>(true, true, true),
    vec3<bool>(true, false, true),
    vec3<bool>(false, true, true),
    vec3<bool>(false, false, true),
);

const bottom_face_vertices = array<vec3<bool>, 4>(
    vec3<bool>(false, false, false),
    vec3<bool>(false, false, true),
    vec3<bool>(true, false, false),
    vec3<bool>(true, false, true),
);

const top_face_vertices = array<vec3<bool>, 4>(
    vec3<bool>(false, true, true),
    vec3<bool>(false, true, false),
    vec3<bool>(true, true, true),
    vec3<bool>(true, true, false),
);



const vertices_position = array<array<vec3<bool>, 4>, 6>(
    west_face_vertices,
    east_face_vertices,
    south_face_vertices,
    north_face_vertices,
    bottom_face_vertices,
    top_face_vertices,
);

const test_square = array<vec4f, 4>(
    vec4f(0, 1, 0.5, 1),
    vec4f(0, 0, 0.5, 1),
    vec4f(1, 1, 0.5, 1),
    vec4f(1, 0, 0.5, 1),
);

struct VertexOut {
    @builtin(position) pos: vec4f,
    @location(0) uv: vec2f,
    @location(1) @interpolate(flat) texture_index: u32,
}

@vertex fn main(@builtin(vertex_index) index: u32) -> VertexOut {
    let face_index = index / 4;
    let index_rel = index % 4;
    
    let face_int = faces[face_index];
    let rel_vertex_position = vec3u(vertices_position[extractBits(face_int, 12, 3)][index_rel]);
    let subchunk_position = (vec3u(face_int) >> vec3u(0, 4, 8)) & vec3u(0xF);
    
    let worldspace_position_3u = chunk_pos * 16 + subchunk_position + rel_vertex_position;
    let worldspace_position = vec4f(vec4u(worldspace_position_3u, 1));

    let pos = perspective_mat * camera_transform_mat * worldspace_position;
    let uv = vec2f(vec2u(index_rel & 2, index_rel & 1) != vec2u(0));

    let texture_index = extractBits(face_int, 16, 16);

    return VertexOut(pos, uv, texture_index);
}