#include <assert.h>
#include <stdio.h>
#include "ghostty_activity.h"
#include "ghostty_input.h"

static void test_mouse_policy(void) {
    for (int overlay = 0; overlay < 2; overlay++) {
        for (int left = 0; left < 2; left++) {
            for (int pressed = 0; pressed < 2; pressed++) {
                bool suppress = false;
                CanopyMouseDecision decision = CanopyTerminalMouseInput(overlay, left, pressed, &suppress);
                assert(decision == (!overlay ? CANOPY_MOUSE_FORWARD :
                    (left && pressed ? CANOPY_MOUSE_DISMISS_SIDEBAR : CANOPY_MOUSE_BLOCK)));
                assert(suppress == (overlay && left && pressed));
            }
        }
    }
    bool suppress = false;
    assert(CanopyTerminalMouseInput(true, true, true, &suppress) == CANOPY_MOUSE_DISMISS_SIDEBAR);
    // Overlay closes between down/up; an unrelated release cannot consume it.
    assert(CanopyTerminalMouseInput(false, false, false, &suppress) == CANOPY_MOUSE_FORWARD);
    assert(suppress);
    assert(CanopyTerminalMouseInput(false, true, false, &suppress) == CANOPY_MOUSE_BLOCK);
    assert(!suppress);
    assert(CanopyTerminalMouseInput(false, true, true, &suppress) == CANOPY_MOUSE_FORWARD);
    assert(CanopyTerminalMouseInput(false, true, false, &suppress) == CANOPY_MOUSE_FORWARD);
}

int main(void) {
    test_mouse_policy();
    for (unsigned bits = 0; bits < 32; bits++) {
        CanopyTerminalFocusState state = {
            .app_active = (bits & 1) != 0, .window_key = (bits & 2) != 0,
            .responder = (bits & 4) != 0, .presented = (bits & 8) != 0,
            .visible = (bits & 16) != 0,
        };
        CanopyTerminalFocusGate gate = {0};
        assert(CanopyTerminalFocusUpdate(&gate, state));
        assert(gate.focused == (bits == 31));
        assert(!CanopyTerminalFocusUpdate(&gate, state));
    }
    CanopyTerminalFocusGate gate = {0};
    CanopyTerminalFocusState state = {true, true, true, true, true};
    assert(CanopyTerminalFocusUpdate(&gate, state) && gate.focused);
    state.app_active = false; // first responder stays the same in a background window
    assert(CanopyTerminalFocusUpdate(&gate, state) && !gate.focused);
    state.app_active = true;
    assert(CanopyTerminalFocusUpdate(&gate, state) && gate.focused);
    state.responder = false; // a field/sidebar owns the keyboard
    assert(CanopyTerminalFocusUpdate(&gate, state) && !gate.focused);
    state.app_active = false;
    assert(!CanopyTerminalFocusUpdate(&gate, state));
    state.app_active = true; // activation must not steal focus back
    assert(!CanopyTerminalFocusUpdate(&gate, state));
    puts("Ghostty activity: all 32 focus states, mouse gating and paired-release checks passed");
    return 0;
}
