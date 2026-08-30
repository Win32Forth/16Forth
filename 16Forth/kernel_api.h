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

#ifdef __cplusplus
}
#endif
#endif
