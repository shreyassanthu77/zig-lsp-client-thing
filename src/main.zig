const std = @import("std");
const json = std.json;
const log = std.log.scoped(.main);
const Allocator = std.mem.Allocator;
const Child = std.process.Child;
const lsp = @import("lsp");
const LSPClient = @import("root.zig");

const Client = LSPClient.create(.{
    .RequestParams = union(enum) {
        initialize: lsp.types.InitializeParams,
        other: lsp.MethodWithParams,
    },
    .NotificationParams = union(enum) {
        @"window/showMessage": lsp.types.ShowMessageParams,
        other: lsp.MethodWithParams,
    },
});

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var child = try launchZLS(alloc);
    var client = try Client.init(alloc, child.stdin.?, child.stdout.?, struct {
        fn onNotify(notification: Client.Notification) void {
            switch (notification) {
                .@"window/showMessage" => |params| {
                    const p: lsp.types.ShowMessageParams = params;
                    log.info("notification: {s}", .{p.message});
                },
                else => {},
            }
        }
    }.onNotify);
    defer client.deinit();

    var config = (try client.request(.{
        .initialize = lsp.types.InitializeParams{
            .capabilities = .{
                .workspace = .{
                    .configuration = true,
                },
                .textDocument = .{
                    .hover = .{
                        .contentFormat = &.{.plaintext},
                    },
                },
            },
        },
    }, lsp.types.InitializeResult)).unwrap();
    defer config.deinit();
    log.info("config: {any}", .{config.value});

    _ = try child.wait();
}

pub fn launchZLS(
    alloc: Allocator,
) !Child {
    var child = Child.init(&.{"zls"}, alloc);
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    try child.spawn();
    return child;
}
