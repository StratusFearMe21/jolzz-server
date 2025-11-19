const std = @import("std");
const JolzzServer = @import("jolzz_server.zig").JolzzServer;

const server_ip: []const u8 = "0.0.0.0";
const server_port: u16 = 3333;

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer if (gpa.deinit() == .leak) @panic("Memory leaks detected");

    var jolzz_server = try JolzzServer.init(gpa.allocator(), server_ip, server_port);
    defer jolzz_server.deinit();

    jolzz_server.connectionListener();
}
