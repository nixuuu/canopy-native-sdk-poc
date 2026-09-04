#include <assert.h>
#include <stdio.h>
#include "ghostty_activity.h"

int main(void) {
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
    puts("Ghostty activity: all 32 focus states and transition checks passed");
    return 0;
}
