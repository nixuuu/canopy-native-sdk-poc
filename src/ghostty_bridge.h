#pragma once
#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>
typedef struct { const char *name; const char *value; } canopy_ghostty_env;
typedef struct { uint64_t tab; int kind; int code; } canopy_ghostty_event;
void *canopy_ghostty_create(const char *const *files, size_t count);
void canopy_ghostty_set_wakeup(void *, void (*)(void *), void *);
void canopy_ghostty_destroy(void *);
void canopy_ghostty_tick(void *);
bool canopy_ghostty_next_event(void *, canopy_ghostty_event *);
void *canopy_ghostty_surface(void *, uint64_t, const char *, const char *, const canopy_ghostty_env *, size_t);
void canopy_ghostty_close(void *, uint64_t);
void canopy_ghostty_visibility(void *, uint64_t, bool, bool);
void canopy_ghostty_cover(void *, uint64_t, double, bool);
void canopy_ghostty_begin_layout(void *, uint64_t);
