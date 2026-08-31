#ifndef SIXTEENFORTH_KERNEL_API_H
#define SIXTEENFORTH_KERNEL_API_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

void kernel_cold_start(void);
int  kernel_eval(const char *line, size_t n);
int  kernel_data_depth(void);

void kernel_set_emit(void (*fn)(int c));
void kernel_set_emit_buf(void (*fn)(const char *buf, size_t n));

/// FROMLIB — arm next load/CHDIR/DIR to Resources/Library.
void kernel_set_fromlib(void (*fn)(void));
/// Disarm FROMLIB (REQUIRE skip / failed load).
void kernel_set_fromlib_clear(void (*fn)(void));
/// File INCLUDE SOURCE ended (SOURCE-ID was > 0) — restore load cwd.
void kernel_set_end_include(void (*fn)(void));

/// INCLUDE / FLOAD / REQUIRE.
/// path_len == 0 → bare (host open panel). On success set *out_ptr / *out_len
/// (buffer valid until host frees after kernel_eval). Return 0 ok, -1 fail/cancel.
typedef int (*kernel_load_file_fn)(const char *path, size_t path_len,
                                   const char **out_ptr, size_t *out_len);
void kernel_set_load_file(kernel_load_file_fn fn);

/// Resolve load name → absolute registry key (consumes FROMLIB). Return 0 ok, -1 fail.
typedef int (*kernel_resolve_key_fn)(const char *path, size_t path_len,
                                     char *out, size_t out_max, size_t *out_len);
void kernel_set_resolve_key(kernel_resolve_key_fn fn);

/// Absolute path of last successful load_file (REQUIRE registry). Return 0 ok, -1 none.
typedef int (*kernel_last_load_key_fn)(char *out, size_t out_max, size_t *out_len);
void kernel_set_last_load_key(kernel_last_load_key_fn fn);

/// CHDIR — path_len == 0 → bare folder picker.
void kernel_set_chdir(void (*fn)(const char *path, size_t n));
/// PWD — print logical cwd.
void kernel_set_pwd(void (*fn)(void));
/// DIR — path_len == 0 → list cwd (or Library if FROMLIB armed).
void kernel_set_dir(void (*fn)(const char *path, size_t n));

/// \S on console SOURCE: sticky flag for multi-line paste stop.
/// Returns 1 if set since last call, else 0; always clears.
int kernel_take_repl_batch_stop(void);

#ifdef __cplusplus
}
#endif
#endif
