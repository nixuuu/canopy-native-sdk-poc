//! Shared application contracts, independent of orchestration and host.
pub const Model = @import("model.zig").Model;
pub const Msg = @import("messages.zig").Msg;
pub const Effects = @import("native_sdk").Effects(Msg);
