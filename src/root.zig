pub const Terminal = @import("Terminal.zig");
pub const event = @import("event.zig");
pub const Event = event.Event;
pub const Key = event.Key;
pub const input = @import("input.zig");
pub const Widget = @import("Widget.zig");
pub const App = @import("App.zig");
pub const TextInput = @import("widgets/TextInput.zig");

test {
    _ = Terminal;
    _ = event;
    _ = input;
    _ = Widget;
    _ = App;
    _ = TextInput;
}
