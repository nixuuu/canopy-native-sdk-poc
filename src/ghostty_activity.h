#pragma once
#include <stdbool.h>

typedef struct {
    bool app_active;
    bool window_key;
    bool responder;
    bool presented;
    bool visible;
} CanopyTerminalFocusState;

typedef struct { bool known; bool focused; } CanopyTerminalFocusGate;

// Ghostty's app focus is a separate API; renderer activity follows SURFACE
// focus. Initial false must also be sent because Ghostty starts focused.
static inline bool CanopyTerminalFocusUpdate(CanopyTerminalFocusGate *gate,
                                             CanopyTerminalFocusState state) {
    bool focused = state.app_active && state.window_key && state.responder &&
        state.presented && state.visible;
    bool changed = !gate->known || gate->focused != focused;
    gate->known = true;
    gate->focused = focused;
    return changed;
}
