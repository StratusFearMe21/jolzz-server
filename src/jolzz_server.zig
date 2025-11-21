const std = @import("std");
const net = std.net;
const Server = net.Server;
const Connection = Server.Connection;
const Allocator = std.mem.Allocator;

pub const JolzzServer = struct {
    ip: []const u8,
    port: u16,
    server: Server,
    allocator: Allocator,
    connections: std.array_list.Aligned(std.Thread, null),
    websocket_instances: std.array_list.Aligned(WebSocketInstance, null),
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
            .connections = try std.ArrayList(std.Thread).initCapacity(allocator, 8),
            .websocket_instances = try std.ArrayList(WebSocketInstance).initCapacity(allocator, 8),
        };
    }

    pub fn deinit(self: *Self) void {
        self.server.deinit();

        self.shutdown_server = true;
        for (self.connections.items) |connection|
            connection.join();

        for (self.websocket_instances.items) |websocket|
            websocket.deinit();

        self.connections.deinit(self.allocator);
        self.websocket_instances.deinit(self.allocator);
    }

    pub fn connectionListener(self: *Self) void {
        while (getConnection(&self.server)) |connection| {
            std.debug.print("Found listener\n", .{});

            var websocket = WebSocketInstance.init(self.allocator, connection) catch
                @panic("Could not create WebSocketInstance");
            errdefer websocket.deinit();

            const thread = std.Thread.spawn(
                .{ .allocator = self.allocator },
                runSocket,
                .{ &websocket, &self.shutdown_server },
            ) catch |err| {
                std.debug.print("Could not make thread: {any}", .{err});
                return;
            };

            self.connections.append(self.allocator, thread) catch @panic("OOM");
            self.websocket_instances.append(self.allocator, websocket) catch @panic("OOM");
        }
    }

    fn runSocket(websocket: *WebSocketInstance, shutdown_server: *bool) void {
        var receive_buffer: [4096]u8 = undefined;
        var header_offset: usize = 0;

        while (readFromConnection(websocket, receive_buffer[header_offset..])) |receive_length| {
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

        upgradeConnection(websocket, header_data) catch
            @panic("An error occured while upgrading the connection");

        while (!shutdown_server.*) {
            var buffer: [4096]u8 = undefined;
            websocketRead(websocket, &buffer) catch {
                std.debug.print("WebSocket read failed\n", .{});
            };
        }
    }

    fn upgradeConnection(websocket: *WebSocketInstance, header_data: []const u8) !void {
        var connection_upgrade = false;
        var websocket_upgrade = false;
        var websocket_version = false;
        var obtained_client_key = false;
        var sec_client_key: [24]u8 = undefined;
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

        const sec_server_key = try generateServerKey(websocket.allocator, &sec_client_key);
        defer websocket.allocator.free(sec_server_key);
        if (connection_upgrade and websocket_upgrade and websocket_version and obtained_client_key) {
            var writer = websocket.connection.stream.writer(&.{});
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

    fn websocketRead(websocket: *WebSocketInstance, buffer: []u8) !void {
        const message_length = try websocket.connection.stream.read(buffer);
        var seek: usize = 0;

        while (seek < message_length) {
            const frame = parseFrame(&seek, buffer) orelse continue;
            std.debug.print("{s}\n", .{frame});
        }
    }

    fn parseFrame(seek: *usize, buffer: []u8) ?[]const u8 {
        const fin = (buffer[seek.*] & 0x80) != 0;
        const opcode = buffer[seek.*] & 0x0F;
        seek.* += 1;

        const is_masked = (buffer[seek.*] & 0x80) != 0;
        var payload_len: usize = buffer[seek.*] & 0x7F;
        seek.* += 1;

        if (!fin) {
            std.debug.print("Fragmenting messages not supported\n", .{});
            return null;
        }

        if (opcode != 1) {
            std.debug.print("Only text is valid for messages\n", .{});
            return null;
        }

        if (payload_len == 126) {
            const current_byte: usize = buffer[seek.*];
            const next_byte: usize = buffer[seek.* + 1];
            payload_len = (current_byte << 8) + next_byte;
            seek.* += 2;
        } else if (payload_len == 127) {
            payload_len = 0;
            for (0..8) |i| {
                const current_byte: usize = buffer[i + seek.*];
                const offset_byte: u6 = @intCast((7 - i) * 8);
                payload_len += current_byte << offset_byte;
            }

            seek.* += 8;
        }

        if (is_masked) {
            const mask_key = buffer[seek.* .. seek.* + 4];
            seek.* += 4;

            for (0..payload_len) |i| {
                const payload_index = seek.* + i;
                buffer[payload_index] = buffer[payload_index] ^ mask_key[i % 4];
            }
        }

        const frame = buffer[seek.* .. seek.* + payload_len];
        seek.* += payload_len;

        return frame;
    }

    fn websocketMessage(websocket: *WebSocketInstance, message: []const u8) !void {
        var buffer: [4096]u8 = undefined;
        createFrame(&buffer);
        try websocket.connection.stream.write(message);
    }

    fn createFrame(buffer: []u8) []const u8 {
        _ = buffer;
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

    fn readFromConnection(websocket: *WebSocketInstance, buffer: []u8) ?usize {
        const length = websocket.connection.stream.read(buffer) catch return null;
        return if (length > 0) length else null;
    }
};

const WebSocketInstance = struct {
    allocator: Allocator,
    connection: Connection,
    server: *std.http.Server,

    pub fn init(allocator: Allocator, connection: Connection) !WebSocketInstance {
        const reader_buffer: []u8 = try allocator.alloc(u8, std.heap.pageSize());
        var stream_reader = connection.stream.reader(reader_buffer);

        const writer_buffer: []u8 = try allocator.alloc(u8, std.heap.pageSize());
        var stream_writer = connection.stream.writer(writer_buffer);

        var server = std.http.Server.init(stream_reader.interface(), &stream_writer.interface);

        return .{
            .allocator = allocator,
            .connection = connection,
            .server = &server,
        };
    }

    pub fn deinit(websocket: WebSocketInstance) void {
        websocket.connection.stream.close();
        // websocket.allocator.free(websocket.reader.buffer);
        // websocket.allocator.free(websocket.writer.buffer);
    }
};
