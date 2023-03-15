const std = @import("std");
const math = std.math;
const glfw = @import("glfw");
const zgpu = @import("zgpu");
const wgpu = zgpu.wgpu;
const zm = @import("zmath");

const wgsl_vs =
\\  @group(0) @binding(0) var<uniform> object_to_clip: mat4x4<f32>;
\\  struct VertexOut {
\\      @builtin(position) position_clip: vec4<f32>,
\\      @location(0) color: vec3<f32>,
\\  }
\\  @stage(vertex) fn main(
\\      @location(0) position: vec3<f32>,
\\      @location(1) pos_cube: vec3<f32>,
\\      @location(2) color: vec3<f32>,
\\  ) -> VertexOut {
\\      var output: VertexOut;
\\      var model_matrix = mat4x4<f32>(
\\          1.0, 0.0 , 0.0, pos_cube.x,
\\          0.0, 1.0 , 0.0, pos_cube.y,
\\          0.0, 0.0 , 1.0, pos_cube.z,
\\          0.0, 0.0 , 0.0, 1.0
\\      );
\\      output.position_clip = vec4(position, 1.0) * model_matrix * object_to_clip;
\\      output.color = color;
\\      return output;
\\  }
;
const wgsl_fs =
\\  @stage(fragment) fn main(
\\      @location(0) color: vec3<f32>,
\\  ) -> @location(0) vec4<f32> {
\\      return vec4(color, 1.0);
\\  }
// zig fmt: on
;
const Vertex = struct {
    position: [3]f32,
};

const Instance = struct {
    pos_cube: [3]f32,
    color: [3]f32,
};

const DemoState = struct {
    gctx: *zgpu.GraphicsContext,

    pipeline: zgpu.RenderPipelineHandle,
    bind_group: zgpu.BindGroupHandle,

    vertex_buffer: zgpu.BufferHandle,
    index_buffer: zgpu.BufferHandle,
    instance_buffer: zgpu.BufferHandle,

    depth_texture: zgpu.TextureHandle,
    depth_texture_view: zgpu.TextureViewHandle,
};

pub const Camera = struct {
    pos: zm.F32x4,
    target: zm.F32x4,
    up: zm.F32x4,
    aspect: f32,
    fovy: f32,
    znear: f32,
    zfar: f32,
    sense: f64,
    speed: f32,
    vert_ang: f32,
    hor_ang: f32,

    const Self = @This();

    pub fn build_view_project_matrix(self: *const Self) zm.Mat {
        const view = zm.lookAtLh(self.pos, self.target, self.up);
        const project = zm.perspectiveFovLh(self.fovy, self.aspect, self.znear, self.zfar);
        return zm.mul(view, project);
    }

    pub fn update_cam(self: *Self, window: glfw.Window) !void {
        if(window.getMouseButton(.left) == .press) {
            const size = try window.getSize();
            const hor_center = @intToFloat(f64, size.width / 2);
            const ver_center = @intToFloat(f64, size.height / 2);
            const actual_pos = try window.getCursorPos();
            try window.setCursorPos( hor_center, ver_center);
            try window.setInputModeCursor(.hidden);
            
            // std.debug.print("x: {d:.2}, y: {d:.2}\n", .{actual_pos.xpos, actual_pos.ypos});
            self.vert_ang += @floatCast(f32, (ver_center - actual_pos.ypos) * self.sense);
            self.hor_ang -= @floatCast(f32, (actual_pos.xpos - hor_center) * self.sense);
        } else {
            try window.setInputModeCursor(.normal);
        }
        const foward = zm.normalize3(zm.f32x4(
            zm.cos(self.hor_ang),
            zm.sin(self.vert_ang),
            zm.sin(self.hor_ang),
            1.0
        ));
        const speed = zm.splat(zm.F32x4, self.speed);

        if(window.getKey(.w) == .press) {   
            self.pos += foward * speed;
        }

        if(window.getKey(.s) == .press) {
            self.pos -= foward * speed;
        }

        const right = zm.normalize3(zm.cross3(self.up, foward));

        if(window.getKey(.a) == .press) {
            self.pos -= right * speed;
        }

        if(window.getKey(.d) == .press) {
            self.pos += right * speed;
        }

        if(window.getKey(.left_shift) == .press) {
            self.pos += self.up * speed;
        }

        if(window.getKey(.left_control) == .press) {
            self.pos -= self.up * speed;
        }
        // std.debug.print("x: {d:.2}, y: {d:.2}, z: {d:.2}\n", .{foward[0], foward[1], foward[2]});
        self.target = self.pos + foward;
    }
};

pub fn init(allocator: std.mem.Allocator, window: glfw.Window) !DemoState {
    const gctx = try zgpu.GraphicsContext.init(allocator, window);

    // Create a bind group layout needed for our render pipeline.
    const bind_group_layout = gctx.createBindGroupLayout(&.{
        zgpu.bglBuffer(0, .{ .vertex = true }, .uniform, true, 0),
    });
    defer gctx.releaseResource(bind_group_layout);

    const pipeline_layout = gctx.createPipelineLayout(&.{bind_group_layout});
    defer gctx.releaseResource(pipeline_layout);

    const pipeline = pipline: {
        const vs_module = zgpu.util.createWgslShaderModule(gctx.device, wgsl_vs, "vs");
        defer vs_module.release();

        const fs_module = zgpu.util.createWgslShaderModule(gctx.device, wgsl_fs, "fs");
        defer fs_module.release();

        const color_targets = [_]wgpu.ColorTargetState{.{
            .format = zgpu.GraphicsContext.swapchain_format,
        }};

        const vertex_attributes = [_]wgpu.VertexAttribute{
            .{ .format = .float32x3, .offset = 0, .shader_location = 0 },
        };

        const instance_attributes = [_]wgpu.VertexAttribute{
            .{ .format = .float32x3, .offset = @offsetOf(Instance, "pos_cube"), .shader_location = 1},
            .{ .format = .float32x3, .offset = @offsetOf(Instance, "color"), .shader_location = 2}
        };


        const vertex_buffers = [_]wgpu.VertexBufferLayout{.{
            .array_stride = @sizeOf(Vertex),
            .attribute_count = vertex_attributes.len,
            .attributes = &vertex_attributes,
        }, 
        .{
            .array_stride = @sizeOf(Instance),
            .attribute_count = instance_attributes.len,
            .attributes = &instance_attributes,
            .step_mode = .instance,
        }        
        };

        const pipeline_descriptor = wgpu.RenderPipelineDescriptor{
            .vertex = wgpu.VertexState{
                .module = vs_module,
                .entry_point = "main",
                .buffer_count = vertex_buffers.len,
                .buffers = &vertex_buffers,
            },
            .primitive = wgpu.PrimitiveState{
                .front_face = .ccw,
                .cull_mode = .none,
                .topology = .triangle_list,
            },
            .depth_stencil = &wgpu.DepthStencilState{
                .format = .depth32_float,
                .depth_write_enabled = true,
                .depth_compare = .less,
            },
            .fragment = &wgpu.FragmentState{
                .module = fs_module,
                .entry_point = "main",
                .target_count = color_targets.len,
                .targets = &color_targets,
            },
        };
        break :pipline gctx.createRenderPipeline(pipeline_layout, pipeline_descriptor);
    };

    const bind_group = gctx.createBindGroup(bind_group_layout, &[_]zgpu.BindGroupEntryInfo{
        .{ .binding = 0, .buffer_handle = gctx.uniforms.buffer, .offset = 0, .size = @sizeOf(zm.Mat) },
    });

   
    // create a intance buffer

    const instance_buffer = gctx.createBuffer(.{
        .usage = .{ .copy_dst = true, .vertex = true},
        .size = 3 * @sizeOf(Instance),
    });
    
   
    const instance_data = [_]Instance{
        .{ .pos_cube = [3]f32{-1.0, 0.0, 0.0}, .color = [3]f32{ 1.0, 0.0, 0.0 }},
        .{ .pos_cube = [3]f32{1.0, 0.0, 0.0}, .color = [3]f32{ 0.0, 1.0, 0.0 }},
        .{ .pos_cube = [3]f32{0.0, 1.0, 0.0}, .color = [3]f32{ 0.0, 0.0, 1.0 }}
    };

    gctx.queue.writeBuffer(gctx.lookupResource(instance_buffer).?, 0, Instance, instance_data[0..]);

    // Create a vertex buffer.
    const vertex_buffer = gctx.createBuffer(.{
        .usage = .{ .copy_dst = true, .vertex = true },
        .size = 8 * @sizeOf(Vertex),
    });
    const vertex_data = [_]Vertex{
        .{ .position = [3]f32{ 0.5, 0.5, -0.5 } }, // T D  0
        .{ .position = [3]f32{ -0.5, 0.5, -0.5 } }, // T E 1
        .{ .position = [3]f32{ -0.5, -0.5, -0.5 } }, // D E 2
        .{ .position = [3]f32{ 0.5, -0.5, -0.5 } }, // D D 3

        .{ .position = [3]f32{ 0.5, 0.5, 0.5 } }, // T D  4
        .{ .position = [3]f32{ -0.5, 0.5, 0.5 } },// T E  5
        .{ .position = [3]f32{ -0.5, -0.5, 0.5 } },// D E 6
        .{ .position = [3]f32{ 0.5, -0.5, 0.5 } } // D D  7
    };
    gctx.queue.writeBuffer(gctx.lookupResource(vertex_buffer).?, 0, Vertex, vertex_data[0..]);

    // Create an index buffer.
    const index_buffer = gctx.createBuffer(.{
        .usage = .{ .copy_dst = true, .index = true },
        .size = 36 * @sizeOf(u16),
    });
    const index_data = [_]u16{ 
        0, 1, 2, 0, 2, 3, // frente
        4, 5, 6, 4, 6, 7, // costas
        0, 4, 5, 0, 5, 1, // top
        3, 7, 6, 3, 6, 2, //baixo
        0, 3, 4, 4, 7, 3, // direita
        1, 2, 5, 2, 6, 5  //esquerda
    };
    gctx.queue.writeBuffer(gctx.lookupResource(index_buffer).?, 0, u16, index_data[0..]);

    // Create a depth texture and its 'view'.
    const depth = createDepthTexture(gctx);

    return DemoState{
        .gctx = gctx,
        .pipeline = pipeline,
        .bind_group = bind_group,
        .vertex_buffer = vertex_buffer,
        .index_buffer = index_buffer,
        .instance_buffer = instance_buffer,
        .depth_texture = depth.texture,
        .depth_texture_view = depth.view,
    };
}

pub fn deinit(allocator: std.mem.Allocator, demo: *DemoState) void {
    demo.gctx.deinit(allocator);
    demo.* = undefined;
}

// fn update(demo: *DemoState) void {
//     zgpu.gui.newFrame(demo.gctx.swapchain_descriptor.width, demo.gctx.swapchain_descriptor.height);
//     zgui.showDemoWindow(null);
// }

pub fn draw(demo: *DemoState, cam: *const Camera) void {
    const gctx = demo.gctx;
    
 
    const cam_world_to_clip = cam.build_view_project_matrix();

    const back_buffer_view = gctx.swapchain.getCurrentTextureView();
    defer back_buffer_view.release();

    const commands = commands: {
        const encoder = gctx.device.createCommandEncoder(null);
        defer encoder.release();

        pass: {
            const vb_info = gctx.lookupResourceInfo(demo.vertex_buffer) orelse break :pass;
            const it_info = gctx.lookupResourceInfo(demo.instance_buffer) orelse break :pass;
            const ib_info = gctx.lookupResourceInfo(demo.index_buffer) orelse break :pass;
            const pipeline = gctx.lookupResource(demo.pipeline) orelse break :pass;
            const bind_group = gctx.lookupResource(demo.bind_group) orelse break :pass;
            const depth_view = gctx.lookupResource(demo.depth_texture_view) orelse break :pass;

            const color_attachments = [_]wgpu.RenderPassColorAttachment{.{
                .view = back_buffer_view,
                .load_op = .clear,
                .store_op = .store,
                .clear_value = .{ .r = 0.2, .g = 0.7, .b = 0.9, .a = 1.0}
            }};
            const depth_attachment = wgpu.RenderPassDepthStencilAttachment{
                .view = depth_view,
                .depth_load_op = .clear,
                .depth_store_op = .store,
                .depth_clear_value = 1.0,
            };
            const render_pass_info = wgpu.RenderPassDescriptor{
                .color_attachment_count = color_attachments.len,
                .color_attachments = &color_attachments,
                .depth_stencil_attachment = &depth_attachment,
            };
            const pass = encoder.beginRenderPass(render_pass_info);
            defer {
                pass.end();
                pass.release();
            }

            pass.setVertexBuffer(0, vb_info.gpuobj.?, 0, vb_info.size);
            pass.setVertexBuffer(1, it_info.gpuobj.?, 0, it_info.size);
            pass.setIndexBuffer(ib_info.gpuobj.?, .uint16, 0, ib_info.size);

            pass.setPipeline(pipeline);

            // draw here

            const object_to_world =  zm.scaling(0.1,0.1,0.1);
            const object_to_clip = zm.mul(object_to_world, cam_world_to_clip);

            const mem = gctx.uniformsAllocate(zm.Mat, 1);
            mem.slice[0] = zm.transpose(object_to_clip);

            pass.setBindGroup(0, bind_group, &.{mem.offset});
            pass.drawIndexed(36, 3, 0, 0, 0);
            
        }

        break :commands encoder.finish(null);
    };
    defer commands.release();

    gctx.submit(&.{commands});

    if (gctx.present() == .swap_chain_resized) {
        // Release old depth texture.
        gctx.releaseResource(demo.depth_texture_view);
        gctx.destroyResource(demo.depth_texture);

        // Create a new depth texture to match the new window size.
        const depth = createDepthTexture(gctx);
        demo.depth_texture = depth.texture;
        demo.depth_texture_view = depth.view;
    }
}

fn createDepthTexture(gctx: *zgpu.GraphicsContext) struct {
    texture: zgpu.TextureHandle,
    view: zgpu.TextureViewHandle,
} {
    const texture = gctx.createTexture(.{
        .usage = .{ .render_attachment = true },
        .dimension = .tdim_2d,
        .size = .{
            .width = gctx.swapchain_descriptor.width,
            .height = gctx.swapchain_descriptor.height,
            .depth_or_array_layers = 1,
        },
        .format = .depth32_float,
        .mip_level_count = 1,
        .sample_count = 1,
    });
    const view = gctx.createTextureView(texture, .{});
    return .{ .texture = texture, .view = view };
}

// std.debug.print("x: {d:.2}, y: {d:.2}, z: {d:.2}\n", .{self.pos[0], self.pos[1], self.pos[2]});