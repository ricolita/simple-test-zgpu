const std = @import("std");
const math = std.math;
const glfw = @import("glfw");
const zgpu = @import("zgpu");
const wgpu = zgpu.wgpu;
const zgui = zgpu.zgui;
const zm = @import("zmath");
const render = @import("render.zig");


pub fn main() !void {
    try glfw.init(.{});
    defer glfw.terminate();

    const window = try glfw.Window.create(1280, 960, " wgpu in zig", null, null, .{
        .client_api = .no_api,
        .cocoa_retina_framebuffer = true,
    });
    defer window.destroy();
    try window.setSizeLimits(.{ .width = 400, .height = 400 }, .{ .width = null, .height = null });

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();

    var demo = try render.init(allocator, window);
    defer render.deinit(allocator, &demo);

    var cam = render.Camera{ 
        .pos = zm.f32x4(0.0, 0.0, -3.0, 1.0), 
        .target = zm.f32x4(0.0, 0.0, 0.0, 1.0), 
        .up = zm.f32x4(0.0, 1.0, 0.0, 0.0), 
        .aspect = @intToFloat(f32, demo.gctx.swapchain_descriptor.width) / @intToFloat(f32, demo.gctx.swapchain_descriptor.height), 
        .fovy = 0.25 * math.pi, 
        .znear = 0.01, 
        .zfar = 200.0,
        .sense = 0.003,
        .speed = 0.01,
        .vert_ang = 0.0,
        .hor_ang = (@as(f32, math.pi) / 2.0),
    };
    

    while (!window.shouldClose()) {
        try glfw.pollEvents();
        try cam.update_cam(window);
        render.draw(&demo, &cam);
    }
}

