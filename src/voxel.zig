const zm = @import("zmath");

const Voxel = struct {
    normal: [3]f32,
    material: u8,
    albedo: [3]f32,
};

const CompressedVoxel = struct {
    normal: u32,
    albedo: u32,
};

const Chunk = struct {
    pos: [3]f32,
    num_voxels: u32,
    voxels: [8][8][8]CompressedVoxel,
};

