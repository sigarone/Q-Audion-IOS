// SPDX-License-Identifier: MIT
// Q-Audion iOS: liboqs rand.h for SPM

#ifndef OQS_RANDOM_H
#define OQS_RANDOM_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include <oqs/common.h>

#if defined(__cplusplus)
extern "C" {
#endif

#define OQS_RAND_alg_system "system"

OQS_API OQS_STATUS OQS_randombytes_switch_algorithm(const char *algorithm);
OQS_API void OQS_randombytes_custom_algorithm(void (*algorithm_ptr)(uint8_t *, size_t));
OQS_API void OQS_randombytes(uint8_t *random_array, size_t bytes_to_read);

#if defined(__cplusplus)
}
#endif

#endif // OQS_RANDOM_H
