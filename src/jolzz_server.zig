const std = @import("std");
const net = std.net;
const Server = net.Server;
const Connection = Server.Connection;
const Allocator = std.mem.Allocator;

const ServerError = error{
    HeaderMalformed,
    MethodNotSupported,
    ProtoNotSupported,
};

pub const JolzzServer = struct {
    ip: []const u8,
    port: u16,
    server: Server,
    allocator: Allocator,
    connections: std.array_list.Aligned(std.Thread, null),
    shutdown_server: bool = false,

    const Self = @This();

    pub fn init(allocator: Allocator, ip: []const u8, port: u16) !Self {
        std.debug.print("Starting server on {s}:{}\n", .{ ip, port });
        const address = try net.Address.resolveIp(ip, port);
        const listener = try address.listen(.{ .reuse_address = true });
        std.debug.print("Listening on {s}:{}\n", .{ ip, port });

        return .{
            .ip = ip,
            .port = port,
            .server = listener,
            .allocator = allocator,
            .connections = try std.ArrayList(std.Thread).initCapacity(allocator, 1),
        };
    }

    pub fn deinit(self: *Self) void {
        self.server.deinit();

        self.shutdown_server = true;
        for (self.connections.items) |connection|
            connection.join();

        self.connections.deinit(self.allocator);
    }

    pub fn connectionListener(self: *Self) void {
        while (getConnection(&self.server)) |connection| {
            std.debug.print("Found listener\n", .{});
            const thread = std.Thread.spawn(
                .{ .allocator = self.allocator },
                runSocket,
                .{ self.allocator, connection, &self.shutdown_server },
            ) catch |err| {
                std.debug.print("Could not make thread: {any}", .{err});
                return;
            };

            self.connections.append(self.allocator, thread) catch @panic("OOM");
        }
    }

    fn runSocket(allocator: Allocator, connection: Connection, shutdown_server: *bool) void {
        var receive_buffer: [4096]u8 = undefined;
        var header_offset: usize = 0;

        while (readFromConnection(connection, receive_buffer[header_offset..])) |receive_length| {
            header_offset += receive_length;
            const header_termination = std.mem.containsAtLeast(
                u8,
                receive_buffer[0..header_offset],
                1,
                "\r\n\r\n",
            );
            if (header_termination) break;
        }

        const header_data = receive_buffer[0..header_offset];
        std.debug.print("{s}\n", .{header_data});
        if (header_data.len == 0) {
            std.debug.print("Connection successful but no data\n", .{});
            return;
        }

        upgradeConnection(allocator, header_data, connection) catch
            @panic("An error occured while upgrading the connection");

        while (!shutdown_server.*) {}
    }

    fn upgradeConnection(allocator: Allocator, header_data: []const u8, connection: Connection) !void {
        var connection_upgrade = false;
        var websocket_upgrade = false;
        var websocket_version = false;
        var obtained_client_key = false;
        var sec_client_key = std.mem.zeroes([24]u8);
        var iterator = std.mem.splitAny(u8, header_data, "\r\n");
        while (iterator.next()) |header| {
            if (!connection_upgrade)
                connection_upgrade = std.mem.containsAtLeast(u8, header, 1, "Connection: Upgrade");

            if (!websocket_upgrade)
                websocket_upgrade = std.mem.containsAtLeast(u8, header, 1, "Upgrade: websocket");

            if (!websocket_version)
                websocket_version = std.mem.containsAtLeast(u8, header, 1, "Sec-WebSocket-Version: 13");

            if (!obtained_client_key and std.mem.containsAtLeast(u8, header, 1, "Sec-WebSocket-Key")) {
                const split_index = std.mem.lastIndexOf(u8, header, ":").? + 2;
                @memcpy(&sec_client_key, header[split_index..]);
                obtained_client_key = true;
            }
        }

        const sec_server_key = try generateServerKey(allocator, &sec_client_key);
        defer allocator.free(sec_server_key);
        if (connection_upgrade and websocket_upgrade and websocket_version and obtained_client_key) {
            var writer = connection.stream.writer(&.{});
            try writer.interface.print(getSwitchingProtocolsResponse(), .{sec_server_key});
            std.debug.print("Connection upgrading\n", .{});
        } else std.debug.print("Not all values supplied for opening the connection\n", .{});
    }

    fn generateServerKey(allocator: Allocator, client_key: []const u8) ![]const u8 {
        const magic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
        const encoder = std.base64.Base64Encoder.init(std.base64.standard_alphabet_chars, '=');
        var sha1 = std.crypto.hash.Sha1.init(.{});

        const key_magic = try std.mem.concat(allocator, u8, &.{ client_key, magic });
        defer allocator.free(key_magic);

        sha1.update(key_magic);
        const sha1_result = sha1.finalResult();

        const encode_size = encoder.calcSize(sha1_result.len);
        const base64_result = try allocator.alloc(u8, encode_size);
        return encoder.encode(base64_result, &sha1_result);
    }

    inline fn getSwitchingProtocolsResponse() []const u8 {
        return "HTTP/1.1 101 Switching Protocols\r\n" ++
            "Upgrade: websocket\r\n" ++
            "Connection: Upgrade\r\n" ++
            "Sec-WebSocket-Accept: {s}\r\n" ++
            "\r\n";
    }

    fn getConnection(server: *Server) ?Connection {
        return server.accept() catch {
            std.debug.print("Server did not accept the response\n", .{});
            return null;
        };
    }

    fn readFromConnection(connection: Connection, buffer: []u8) ?usize {
        const length = connection.stream.read(buffer) catch return null;
        return if (length > 0) length else null;
    }
};
