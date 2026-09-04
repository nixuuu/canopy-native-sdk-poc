//! Compact Canopy-inspired light/dark token register.

const native_sdk = @import("native_sdk");

const canvas = native_sdk.canvas;
const Color = canvas.Color;

pub fn tokens(appearance: native_sdk.Appearance) canvas.DesignTokens {
    var out = canvas.DesignTokens.theme(.{
        .color_scheme = switch (appearance.color_scheme) {
            .light => .light,
            .dark => .dark,
        },
        .contrast = if (appearance.high_contrast) .high else .standard,
        .density = .compact,
        .reduce_motion = appearance.reduce_motion,
    });

    out.radius = .{ .sm = 3, .md = 4, .lg = 6, .xl = 8 };
    out.spacing = .{ .xs = 4, .sm = 8, .md = 12, .lg = 16, .xl = 20 };
    out.typography.font_id = canvas.default_sans_font_id;
    out.typography.mono_font_id = canvas.default_mono_font_id;
    // Canvas resolves the actual face by font_id. The SDK's built-in sans id
    // is Geist; a different face must be registered explicitly through
    // UiApp.Options.fonts rather than advertised as system_sans metadata.
    out.typography.font_family = .geist;
    out.typography.mono_font_family = .geist_mono;
    // Electron Canopy's base scale is 12px. Preference labels opt into the
    // 13px `lg` rung, while helper copy uses the 11px `sm` rung.
    out.typography.body_size = 12;
    out.typography.label_size = 11;
    out.typography.title_size = 13;
    out.typography.button_size = 13;
    out.typography.heading_size = 14;
    out.typography.display_size = 20;
    out.metrics.control_height_sm = 32;
    out.metrics.control_height = 38;
    out.metrics.control_height_lg = 40;
    out.metrics.button_inset_sm = 7;
    out.metrics.button_inset = 8;
    out.metrics.button_inset_lg = 9;
    out.metrics.button_icon_gap = 5;
    out.metrics.row_extent = 24;
    out.pixel_snap = .{ .geometry = true, .text = true, .scale = 1 };

    if (appearance.high_contrast) return out;

    out.colors = switch (appearance.color_scheme) {
        .light => light_colors,
        .dark => dark_colors,
    };
    // ColorTokens only define the semantic palette. Electron Canopy has
    // control-specific treatments (30% black inputs, quiet accent buttons,
    // neutral active rows), so state those in the SDK's control register
    // instead of overloading surface_pressed or accent_text.
    out.controls = switch (appearance.color_scheme) {
        .light => light_controls,
        .dark => dark_controls,
    };
    if (appearance.color_scheme == .dark) {
        const none = canvas.ShadowToken{ .y = 0, .blur = 0, .spread = 0 };
        out.shadow = .{ .none = none, .xs = none, .sm = none, .md = none };
    }
    return out;
}

pub const light_colors = canvas.ColorTokens{
    .background = Color.rgb8(250, 250, 250),
    .surface = Color.rgb8(238, 238, 238),
    .surface_subtle = Color.rgba8(0, 0, 0, 15),
    .surface_pressed = Color.rgba8(0, 0, 0, 20),
    .text = Color.rgb8(24, 24, 27),
    .text_muted = Color.rgba8(24, 24, 27, 102),
    .syntax_plain = Color.rgb8(39, 39, 42),
    .syntax_comment = Color.rgb8(113, 113, 122),
    .syntax_keyword = Color.rgb8(147, 51, 234),
    .syntax_literal = Color.rgb8(22, 163, 74),
    .syntax_function = Color.rgb8(124, 58, 237),
    .syntax_property = Color.rgb8(225, 29, 72),
    .syntax_constant = Color.rgb8(2, 132, 199),
    .border = Color.rgba8(24, 24, 27, 24),
    .accent = Color.rgb8(52, 132, 198),
    // SDK accent_text is knockout ink ON the solid accent, not Canopy's
    // blue accent label. This blue is dark enough to require white ink.
    .accent_text = Color.rgb8(250, 250, 250),
    .destructive = Color.rgb8(220, 38, 38),
    .destructive_text = Color.rgb8(250, 250, 250),
    .success = Color.rgb8(22, 163, 74),
    .success_text = Color.rgb8(250, 250, 250),
    .warning = Color.rgb8(202, 138, 4),
    .warning_text = Color.rgb8(24, 24, 27),
    .info = Color.rgb8(52, 132, 198),
    .info_text = Color.rgb8(250, 250, 250),
    .focus_ring = Color.rgba8(52, 132, 198, 153),
    .shadow = Color.rgba8(0, 0, 0, 22),
    .scrim = Color.rgba8(0, 0, 0, 128),
    .disabled = Color.rgba8(24, 24, 27, 64),
};

pub const dark_colors = canvas.ColorTokens{
    .background = Color.rgb8(30, 30, 30),
    .surface = Color.rgb8(41, 41, 41),
    .surface_subtle = Color.rgba8(255, 255, 255, 15),
    .surface_pressed = Color.rgba8(255, 255, 255, 20),
    .text = Color.rgba8(224, 224, 224, 219),
    .text_muted = Color.rgba8(224, 224, 224, 102),
    .syntax_plain = Color.rgb8(224, 224, 224),
    .syntax_comment = Color.rgba8(224, 224, 224, 115),
    .syntax_keyword = Color.rgb8(218, 119, 242),
    .syntax_literal = Color.rgb8(105, 219, 124),
    .syntax_function = Color.rgb8(255, 212, 59),
    .syntax_property = Color.rgb8(116, 192, 252),
    .syntax_constant = Color.rgb8(255, 212, 59),
    .border = Color.rgba8(255, 255, 255, 31),
    .accent = Color.rgb8(116, 192, 252),
    // #74c0fc is a light fill; dark knockout ink is the readable pair.
    .accent_text = Color.rgb8(30, 30, 30),
    .destructive = Color.rgb8(255, 107, 107),
    .destructive_text = Color.rgb8(244, 244, 245),
    .success = Color.rgb8(105, 219, 124),
    .success_text = Color.rgb8(30, 30, 30),
    .warning = Color.rgb8(255, 212, 59),
    .warning_text = Color.rgb8(30, 30, 30),
    .info = Color.rgb8(218, 119, 242),
    .info_text = Color.rgb8(30, 30, 30),
    .focus_ring = Color.rgba8(116, 192, 252, 153),
    .shadow = Color.rgba8(0, 0, 0, 153),
    .scrim = Color.rgba8(0, 0, 0, 128),
    .disabled = Color.rgba8(224, 224, 224, 64),
};

const light_controls = canvas.ControlTokens{
    .button_secondary = .{
        .background = Color.rgba8(52, 132, 198, 38),
        .hover_background = Color.rgba8(52, 132, 198, 64),
        .active_background = Color.rgba8(52, 132, 198, 64),
        .foreground = Color.rgb8(28, 92, 145),
        .stroke_width = 0,
    },
    .button_ghost = .{
        .hover_background = Color.rgba8(0, 0, 0, 15),
        .active_background = Color.rgba8(0, 0, 0, 20),
        .foreground = Color.rgba8(24, 24, 27, 102),
    },
    .button_destructive = .{
        .background = Color.rgba8(220, 38, 38, 26),
        .hover_background = Color.rgba8(220, 38, 38, 38),
        .active_background = Color.rgba8(220, 38, 38, 51),
        .foreground = Color.rgb8(220, 38, 38),
        .stroke_width = 0,
    },
    .input = light_input,
    .text_field = light_input,
    .search_field = light_input,
    .combobox = light_input,
    .textarea = light_input,
    .select = light_input,
    .list_item = .{
        .hover_background = Color.rgba8(0, 0, 0, 15),
        .active_background = Color.rgba8(0, 0, 0, 20),
        .pressed_background = Color.rgba8(0, 0, 0, 26),
    },
    .switch_control = .{
        .background = Color.rgba8(0, 0, 0, 15),
        .hover_background = Color.rgba8(0, 0, 0, 26),
        .active_background = Color.rgb8(52, 132, 198),
        .foreground = Color.rgb8(250, 250, 250),
    },
    .scrollbar = .{
        .background = Color.rgba8(0, 0, 0, 38),
        .hover_background = Color.rgba8(0, 0, 0, 77),
        .active_background = Color.rgba8(0, 0, 0, 102),
        .radius = 3,
    },
    .separator = .{ .background = Color.rgba8(0, 0, 0, 15) },
    .dialog = .{ .background = Color.rgba8(250, 250, 250, 250), .border = Color.rgba8(0, 0, 0, 31), .radius = 8 },
};

const dark_controls = canvas.ControlTokens{
    .button_secondary = .{
        .background = Color.rgba8(116, 192, 252, 38),
        .hover_background = Color.rgba8(116, 192, 252, 64),
        .active_background = Color.rgba8(116, 192, 252, 64),
        .foreground = Color.rgba8(116, 192, 252, 230),
        .stroke_width = 0,
    },
    .button_ghost = .{
        .hover_background = Color.rgba8(255, 255, 255, 15),
        .active_background = Color.rgba8(255, 255, 255, 20),
        .foreground = Color.rgba8(224, 224, 224, 102),
    },
    .button_destructive = .{
        .background = Color.rgba8(255, 107, 107, 51),
        .hover_background = Color.rgba8(255, 107, 107, 64),
        .active_background = Color.rgba8(255, 107, 107, 77),
        .foreground = Color.rgba8(255, 107, 107, 230),
        .stroke_width = 0,
    },
    .input = dark_input,
    .text_field = dark_input,
    .search_field = dark_input,
    .combobox = dark_input,
    .textarea = dark_input,
    .select = dark_input,
    .list_item = .{
        .hover_background = Color.rgba8(255, 255, 255, 15),
        .active_background = Color.rgba8(255, 255, 255, 20),
        .pressed_background = Color.rgba8(255, 255, 255, 26),
    },
    .switch_control = .{
        .background = Color.rgba8(0, 0, 0, 77),
        .hover_background = Color.rgba8(255, 255, 255, 20),
        .active_background = Color.rgb8(116, 192, 252),
        .foreground = Color.rgb8(224, 224, 224),
    },
    .scrollbar = .{
        .background = Color.rgba8(255, 255, 255, 38),
        .hover_background = Color.rgba8(255, 255, 255, 77),
        .active_background = Color.rgba8(255, 255, 255, 102),
        .radius = 3,
    },
    .separator = .{ .background = Color.rgba8(255, 255, 255, 15) },
    .dialog = .{ .background = Color.rgba8(30, 30, 30, 250), .border = Color.rgba8(255, 255, 255, 31), .radius = 8 },
};

const light_input = canvas.ControlVisualTokens{
    .background = Color.rgba8(0, 0, 0, 15),
    .hover_background = Color.rgba8(0, 0, 0, 15),
    .border = Color.rgba8(0, 0, 0, 31),
    .radius = 4,
};

const dark_input = canvas.ControlVisualTokens{
    .background = Color.rgba8(0, 0, 0, 77),
    .hover_background = Color.rgba8(0, 0, 0, 77),
    .border = Color.rgba8(255, 255, 255, 31),
    .radius = 4,
};

test "Canopy tokens follow appearance and remain compact" {
    const light = tokens(.{ .color_scheme = .light });
    const dark = tokens(.{ .color_scheme = .dark });
    try @import("std").testing.expectEqual(canvas.Density.compact, dark.density);
    try @import("std").testing.expect(!@import("std").meta.eql(light.colors.background, dark.colors.background));
    try @import("std").testing.expectEqual(@as(f32, 4), dark.radius.md);
    try @import("std").testing.expectEqual(canvas.default_sans_font_id, dark.typography.font_id);
    try @import("std").testing.expectEqual(@as(f32, 0), dark.shadow.md.blur);
    try @import("std").testing.expectEqual(dark_colors.scrim, dark.colors.scrim);
    try @import("std").testing.expectEqual(dark_input.background, dark.controls.text_field.background.?);
    try @import("std").testing.expectEqual(dark_colors.accent_text, dark.colors.accent_text);
}
