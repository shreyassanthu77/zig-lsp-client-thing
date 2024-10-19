const std = @import("std");
const json = std.json;
const Allocator = std.mem.Allocator;
const lsp = @import("lsp");

pub fn create(comptime MessageConfig: lsp.MessageConfig) type {
    return struct {
        const Self = @This();
        pub const Message = lsp.Message(MessageConfig);
        pub const Notification = Self.Message.Notification.Params;

        const InFlightRequest = struct {
            mutex: std.Thread.Mutex = .{},
            cond: std.Thread.Condition = .{},
            resolved: bool = false,
            result: ?json.Parsed(Self.Message) = null,
        };

        arena: std.heap.ArenaAllocator,
        in_stream: std.fs.File,
        out_stream: std.fs.File,
        id: std.atomic.Value(i64) = .{ .raw = 1 },
        in_flight_requests_mutex: std.Thread.Mutex = .{},
        in_flight_requests: std.AutoHashMap(i64, *InFlightRequest),
        read_thread: ?std.Thread = null,
        on_notify: *const fn (Self.Notification) void,

        pub fn init(allocator: Allocator, in_stream: std.fs.File, out_stream: std.fs.File, on_notify: *const fn (Self.Notification) void) !Self {
            return Self{
                .arena = std.heap.ArenaAllocator.init(allocator),
                .in_stream = in_stream,
                .out_stream = out_stream,
                .in_flight_requests = undefined,
                .on_notify = on_notify,
            };
        }

        pub fn deinit(self: *Self) void {
            self.in_flight_requests.deinit();
            self.arena.deinit();
        }

        fn Response(comptime T: type) type {
            return union(enum) {
                ok: json.Parsed(T),
                err: lsp.JsonRPCMessage.Response.Error,

                pub fn unwrap(self: @This()) json.Parsed(T) {
                    switch (self) {
                        .ok => |v| return v,
                        .err => unreachable,
                    }
                }

                pub fn unwrapErr(self: *@This()) lsp.JsonRPCMessage.Response.Error {
                    switch (self.*) {
                        .ok => unreachable,
                        .err => |err| return err,
                    }
                }

                pub fn ok(self: *@This()) ?json.Parsed(T) {
                    switch (self.*) {
                        .ok => |v| return v,
                        .err => unreachable,
                    }
                }
            };
        }
        pub fn request(self: *Self, params: Self.Message.Request.Params, comptime T: type) !Response(T) {
            if (self.read_thread == null) try self.startReadLoop();

            const allocator = self.arena.allocator();
            const id = self.id.fetchAdd(1, .monotonic);
            const msg = Self.Message.Request{
                .id = .{ .number = id },
                .params = params,
            };

            const writer = self.in_stream.writer();
            const json_msg = try json.stringifyAlloc(allocator, msg, .{});
            defer allocator.free(json_msg);

            var req = InFlightRequest{};
            {
                self.in_flight_requests_mutex.lock();
                defer self.in_flight_requests_mutex.unlock();
                try self.in_flight_requests.put(id, &req);
            }
            try std.fmt.format(
                writer,
                "Content-Length: {d}\r\n\r\n{s}",
                .{ json_msg.len, json_msg },
            );
            {
                req.mutex.lock();
                defer req.mutex.unlock();
                while (!req.resolved) {
                    req.cond.wait(&req.mutex);
                }
            }
            {
                self.in_flight_requests_mutex.lock();
                defer self.in_flight_requests_mutex.unlock();
                _ = self.in_flight_requests.remove(id);
            }

            if (req.result) |r| {
                defer r.deinit();
                switch (r.value.response.result_or_error) {
                    .result => |value| {
                        const parsed = try json.parseFromValue(T, allocator, value.?, .{});
                        return Response(T){
                            .ok = parsed,
                        };
                    },
                    .@"error" => |err| {
                        return .{
                            .err = err,
                        };
                    },
                }
            }

            return error.UnexpectedResponse;
        }

        // TODO probably should implement a thread pool
        fn startReadLoop(self: *Self) !void {
            if (self.read_thread != null) return;
            const allocator = self.arena.allocator();
            self.in_flight_requests = std.AutoHashMap(i64, *InFlightRequest).init(allocator);
            self.read_thread = try std.Thread.spawn(.{}, readLoop, .{self});
        }
        fn readLoop(self: *Self) !void {
            const CONTENT_LENGTH = "Content-Length: ";
            const allocator = self.arena.allocator();
            var buf: [1024]u8 = undefined;
            const reader = self.out_stream.reader();
            while (true) {
                const header = try reader.readUntilDelimiterOrEof(&buf, '\n') orelse return error.UnexpectedEndOfInput;
                if (header.len == 0) return error.UnexpectedEndOfInput;
                try reader.skipBytes(2, .{}); // skip next \r\n
                if (!std.mem.startsWith(u8, header, CONTENT_LENGTH)) {
                    @panic("Only Content-Length: is supported");
                }
                const len = try std.fmt.parseInt(
                    usize,
                    header[CONTENT_LENGTH.len .. header.len - 1], // exclude \r\n and Content-Length:
                    10,
                );

                const content_bytes_buf = try allocator.alloc(u8, len);
                defer allocator.free(content_bytes_buf);

                const n = try reader.read(content_bytes_buf);
                std.debug.assert(n == len);

                const content = try Self.Message.parseFromSlice(allocator, content_bytes_buf, .{});

                switch (content.value) {
                    .response => |response| {
                        self.in_flight_requests_mutex.lock();
                        const req: *Self.InFlightRequest = self.in_flight_requests.get(response.id.?.number) orelse {
                            return error.UnexpectedResponse;
                        };
                        self.in_flight_requests_mutex.unlock();

                        req.mutex.lock();
                        req.result = content;
                        req.resolved = true;
                        req.mutex.unlock();
                        req.cond.signal();
                    },
                    .notification => |notification| self.on_notify(notification.params),
                    else => unreachable,
                }
            }
        }
    };
}
