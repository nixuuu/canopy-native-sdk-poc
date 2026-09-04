#pragma once
#include <stdbool.h>

typedef enum {
    CANOPY_MOUSE_FORWARD,
    CANOPY_MOUSE_BLOCK,
    CANOPY_MOUSE_DISMISS_SIDEBAR,
} CanopyMouseDecision;

// Consume the entire click that dismisses navigation, including a mouse-up
// arriving after the overlay has disappeared. Other buttons never dismiss it.
static inline CanopyMouseDecision CanopyTerminalMouseInput(
    bool overlay, bool left, bool pressed, bool *suppress_left_up) {
    if (left && !pressed && *suppress_left_up) {
        *suppress_left_up = false;
        return CANOPY_MOUSE_BLOCK;
    }
    if (!overlay) return CANOPY_MOUSE_FORWARD;
    if (left && pressed) {
        *suppress_left_up = true;
        return CANOPY_MOUSE_DISMISS_SIDEBAR;
    }
    return CANOPY_MOUSE_BLOCK;
}
