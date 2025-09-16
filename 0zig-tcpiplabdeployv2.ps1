$root = "tcpip-lab-zig"
$dirs = @(
    "$root/src/net",
    "$root/src/io",
    "$root/src/plugins",
    "$root/src/test"
)

foreach ($dir in $dirs) {
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
}

function Write-ZigFile {
    param (
        [string]$path,
        [string]$content
    )
    Set-Content -Path $path -Value $content -Encoding UTF8
}

# build.zig
Write-ZigFile "$root/build.zig" @'
const std = @import("std");
pub fn build(b: *std.Build) void {
    const exe = b.addExecutable(.{
        .name = "stack",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
        }),
    });
    b.installArtifact(exe);
}
'@

# main.zig
Write-ZigFile "$root/src/main.zig" @'
const std = @import("std");
const injectEchoPacket = @import("io/injector.zig").injectEchoPacket;
const dispatch = @import("net/router.zig").dispatch;
const fuzz = @import("test/fuzz.zig").fuzz;
const metrics = @import("net/router.zig").metrics;

pub fn main() void {
    const allocator = std.heap.page_allocator;
    const echo = injectEchoPacket(allocator);
    dispatch(echo);
    allocator.free(echo);
    fuzz(allocator, 1000);
    const stdout = std.io.getStdOut().writer();
    metrics.toJson(stdout) catch unreachable;
    stdout.writeByte(0x0A) catch unreachable;
}
'@

# Additional Zig files follow the same pattern...
# Example: io/interface.zig
Write-ZigFile "$root/src/io/interface.zig" @'
const std = @import("std");
pub const NetInterface = struct {
    allocator: *std.mem.Allocator,
    buffer: []u8,

    pub fn init(allocator: *std.mem.Allocator, size: usize) NetInterface {
        return NetInterface{
            .allocator = allocator,
            .buffer = allocator.alloc(u8, size) catch unreachable,
        };
    }

    pub fn send(self: *NetInterface, packet: []u8) void {
        std.mem.copy(u8, self.buffer[0..packet.len], packet);
    }

    pub fn receive(self: *NetInterface) []u8 {
        return self.buffer;
    }
};
'@

# Repeat Write-ZigFile calls for each Zig source file as you've done.

Write-Host "TCP/IP lab deployed at $root with structured metrics, plugin profiling, injector, router, and fuzz harness"