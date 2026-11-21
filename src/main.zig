//! Draws a light simulation to the terminal (you can zoom out for higher resolution)!
const std = @import("std");

const Vec2 = @Vector(2, f64);

fn getDistance(v: Vec2, w: Vec2) f64 {
    const diff = v - w;
    return @sqrt(@reduce(.Add, diff * diff));
}

const State = struct {
    emitter: Body,
    receiver: Body,
    pub fn new() State {
        return State{
            .emitter = Body{
                .position = .{ 0, 0.5 },
                .velocity = .{ 0.01, 0 },
                .radius = 0.01,
                .intensity = 0.5,
            },
            .receiver = Body{
                .position = .{ 1, 0.3 },
                .velocity = .{ 0.01, 0 },
                .radius = 0.01,
                .intensity = 0,
            },
        };
    }
    pub fn step(self: *State) void {
        self.emitter.step();
        self.receiver.step();
    }
    pub fn getIntensities(self: *State, allocator: std.mem.Allocator, rows: usize, cols: usize) ![]u8 {
        const intensities = try allocator.alloc(u8, @intCast(cols * rows * 2));
        for (0..rows) |y| {
            for (0..cols) |x| {
                const top_point = get_point(rows, cols, x, 2 * y);
                const bottom_point = get_point(rows, cols, x, (2 * y) + 1);
                const top_intensity = self.calculateIntensity(top_point);
                const bottom_intensity = self.calculateIntensity(bottom_point);
                const index = (y * cols + x) * 2;
                intensities[index] = top_intensity;
                intensities[index + 1] = bottom_intensity;
            }
        }
        return intensities;
    }
    pub fn isInShadow(self: *State, point: Vec2) bool {
        const ray_dir = self.emitter.position - point;
        const to_receiver = self.receiver.position - point;
        const ray_len_sq = @reduce(.Add, ray_dir * ray_dir);
        if (ray_len_sq == 0.0) return false; // Avoid division by zero if point is on emitter
        const dot = @reduce(.Add, to_receiver * ray_dir);
        var t = dot / ray_len_sq;
        if (t < 0.0) t = 0.0;
        if (t > 1.0) t = 1.0;
        const closest_point = point + (@as(Vec2, @splat(t)) * ray_dir);
        const dist_vec = self.receiver.position - closest_point;
        const dist_sq = @reduce(.Add, dist_vec * dist_vec);
        return dist_sq < (self.receiver.radius * self.receiver.radius);
    }
    pub fn calculateIntensity(self: *State, point: Vec2) u8 {
        if (getDistance(point, self.receiver.position) <= self.receiver.radius) {
            return 0;
        }
        if (getDistance(point, self.emitter.position) <= self.emitter.radius) {
            return 255;
        }
        const shadow_effect: f64 = if (self.isInShadow(point)) 1.1 else 1;
        return calculateFalloff(shadow_effect * getDistance(point, self.emitter.position), self.emitter.intensity);
    }
};

const Terminal = struct {
    stdout_file: std.Io.File,
    stdout_buf: [4 * 1024 * 1024]u8,
    stdout_writer: std.Io.File.Writer,

    pub fn init(io: std.Io) !Terminal {
        var self = Terminal{
            .stdout_file = std.Io.File.stdout(),
            .stdout_buf = undefined,
            .stdout_writer = undefined,
        };
        self.stdout_writer = self.stdout_file.writer(io, &self.stdout_buf);

        const out = &self.stdout_writer.interface;
        try out.print("\x1b[?1049h", .{}); // Switch to alternate screen buffer
        try out.print("\x1b[?25l", .{}); // Hide cursor
        try out.print("\x1b[?7l", .{}); // Disable line wrapping
        try out.flush();
        return self;
    }

    pub fn deinit(self: *Terminal) !void {
        const out = &self.stdout_writer.interface;
        try out.print("\x1b[?7h", .{}); // Re-enable line wrapping
        try out.print("\x1b[?25h", .{}); // Show cursor
        try out.print("\x1b[?1049l", .{}); // Switch back to main screen buffer
        try out.flush();
    }

    pub fn drawFrame(self: *Terminal, state: *State) !void {
        const winsize = try getTerminalSizePosix(self.stdout_file);
        const rows: usize = winsize.row;
        const cols: usize = winsize.col;

        const out = &self.stdout_writer.interface;
        try out.print("\x1b[?2026h\x1b[H", .{});
        for (0..rows) |y| {
            if (y != 0) {
                try out.print("\n", .{});
            }
            for (0..cols) |x| {
                const top_point = get_point(rows, cols, x, 2 * y);
                const bottom_point = get_point(rows, cols, x, (2 * y) + 1);
                const top = state.calculateIntensity(top_point);
                const bot = state.calculateIntensity(bottom_point);
                try out.print("\x1b[38;2;{d};{d};{d}m\x1b[48;2;{d};{d};{d}m▀", .{
                    top,
                    top,
                    top,
                    bot,
                    bot,
                    bot,
                });
            }
            try out.print("\x1b[0m", .{});
        }
        try out.print("\x1b[?2026l", .{});
        try out.flush();
    }
};

// turn integer to floating point
fn get_point(rows: usize, cols: usize, x: usize, y: usize) Vec2 {
    return .{
        @as(f64, @floatFromInt(x)) / @as(f64, @floatFromInt(cols)),
        @as(f64, @floatFromInt(y)) / @as(f64, @floatFromInt(2 * rows)),
    };
}

const Body = struct {
    position: Vec2,
    velocity: Vec2,
    radius: f64,
    intensity: f64,
    pub fn step(self: *Body) void {
        self.position += self.velocity;
        // check left and right
        if (self.position[0] <= 0) {
            self.velocity[0] = @abs(self.velocity[0]);
        } else if (self.position[0] >= 1) {
            self.velocity[0] = -@abs(self.velocity[0]);
        }
        // check top and bottom
        if (self.position[1] <= 0) {
            self.velocity[1] = @abs(self.velocity[1]);
        }
        if (self.position[1] >= 1) {
            self.velocity[1] = -@abs(self.velocity[1]);
        }
    }
};

fn getTerminalSizePosix(out_file: std.Io.File) !std.posix.winsize {
    var winsize: std.posix.winsize = .{
        .row = 0,
        .col = 0,
        .xpixel = 0,
        .ypixel = 0,
    };
    const err = std.posix.system.ioctl(out_file.handle, std.posix.T.IOCGWINSZ, @intFromPtr(&winsize));
    if (std.posix.errno(err) != .SUCCESS) {
        return error.TerminalSizeUnavailable;
    }
    return winsize;
}

fn absDiffUnsigned(x: f64, y: f64) f64 {
    return if (x > y) x - y else y - x;
}

fn calculateFalloff(distance: f64, intensity: f64) u8 {
    return @as(u8, @trunc(@max(0.0, @min(1.0, (1 - distance / intensity))) * 255.0));
}

pub fn main(init: std.process.Init) !void {
    // variable setup
    const io = init.io;
    var screen = try Terminal.init(io);
    defer screen.deinit() catch {};
    // state setup
    const fps = 60;
    const target_frame_time_ns = (1000 * std.time.ns_per_ms) / fps;
    var state = State.new();
    // play loop
    var frame_number: u64 = 0;
    const start_time = std.Io.Timestamp.now(io, .awake);
    while (true) {
        const frame_start_time = std.Io.Timestamp.now(io, .awake);
        while ((frame_number * target_frame_time_ns) < start_time.untilNow(io, .awake).toNanoseconds()) : (frame_number += 1) {
            state.step();
            // std.debug.print("stepped\n", .{});
        }
        try screen.drawFrame(&state);
        // std.debug.print("{any}\n", .{state});
        // wait to cap frame rate
        const elapsed_ns = frame_start_time.untilNow(io, .awake).toNanoseconds();
        if (elapsed_ns < target_frame_time_ns) {
            try io.sleep(std.Io.Duration.fromNanoseconds(target_frame_time_ns - elapsed_ns), .awake);
        }
    }
}
