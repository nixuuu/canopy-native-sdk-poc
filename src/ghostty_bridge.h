#pragma once
#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>
typedef struct { const char *name; const char *value; } canopy_ghostty_env;
typedef enum {
    CANOPY_GHOSTTY_PROCESS_EXIT = 1,
    CANOPY_GHOSTTY_CLOSE_TAB = 2,
    CANOPY_GHOSTTY_NEW_TERMINAL = 3,
    CANOPY_GHOSTTY_DISMISS_SIDEBAR = 4,
} canopy_ghostty_event_kind;
// tab is a never-reused tab identity, not a recyclable PTY key.
typedef struct { uint64_t tab; canopy_ghostty_event_kind kind; int code; } canopy_ghostty_event;
// UI-thread entry points. Strings/arrays are borrowed for the call only.
// create/destroy own the host; returned NSViews are owned by that host.
void *canopy_ghostty_create(const char *const *files, size_t count);
void canopy_ghostty_set_wakeup(void *host, void (*notify)(void *context), void *context);
void canopy_ghostty_destroy(void *host);
void canopy_ghostty_tick(void *host);
bool canopy_ghostty_next_event(void *host, canopy_ghostty_event *event);
void *canopy_ghostty_surface(void *host, uint64_t tab, const char *cwd, const char *command,
                            const canopy_ghostty_env *env, size_t count);
void canopy_ghostty_close(void *host, uint64_t tab);
void canopy_ghostty_visibility(void *host, uint64_t tab, bool visible, bool focus);
void canopy_ghostty_cover(void *host, uint64_t tab, double covered, bool overlay);
void canopy_ghostty_begin_layout(void *host, uint64_t tab);
