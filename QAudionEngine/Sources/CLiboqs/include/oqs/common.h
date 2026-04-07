// SPDX-License-Identifier: MIT
// Q-Audion iOS: liboqs common.h for SPM
// Subset of the real liboqs common.h needed for ML-KEM-1024

#ifndef OQS_COMMON_H
#define OQS_COMMON_H

#include <limits.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

#include <oqs/oqsconfig.h>

#if defined(__cplusplus)
extern "C" {
#endif

// API visibility
#if defined(_WIN32)
#define OQS_API __declspec(dllexport)
#else
#define OQS_API __attribute__((visibility("default")))
#endif

// Return status
typedef enum {
    OQS_ERROR = -1,
    OQS_SUCCESS = 0,
    OQS_EXTERNAL_LIB_ERROR_OPENSSL = 50,
} OQS_STATUS;

// CPU extension detection (simplified for iOS)
typedef enum {
    OQS_CPU_EXT_INIT,
    OQS_CPU_EXT_ARM_AES,
    OQS_CPU_EXT_ARM_SHA2,
    OQS_CPU_EXT_ARM_SHA3,
    OQS_CPU_EXT_ARM_NEON,
    OQS_CPU_EXT_COUNT,
} OQS_CPU_EXT;

OQS_API int OQS_CPU_has_extension(OQS_CPU_EXT ext);
OQS_API void OQS_init(void);
OQS_API void OQS_thread_stop(void);
OQS_API void OQS_destroy(void);
OQS_API const char *OQS_version(void);

// Memory functions
OQS_API void *OQS_MEM_malloc(size_t size);
OQS_API void *OQS_MEM_calloc(size_t num_elements, size_t element_size);
OQS_API char *OQS_MEM_strdup(const char *str);
OQS_API int OQS_MEM_secure_bcmp(const void *a, const void *b, size_t len);
OQS_API void OQS_MEM_cleanse(void *ptr, size_t len);
OQS_API void OQS_MEM_secure_free(void *ptr, size_t len);
OQS_API void OQS_MEM_insecure_free(void *ptr);

#define SIZE_T_TO_INT_OR_EXIT(size_t_var_name, int_var_name) \
  int int_var_name = 0;                                      \
  if (size_t_var_name <= INT_MAX) {                          \
    int_var_name = (int)size_t_var_name;                     \
  } else {                                                   \
    exit(EXIT_FAILURE);                                      \
  }

#define OQS_EXIT_IF_NULLPTR(x, loc)                                       \
  do {                                                                    \
    if ((x) == (void *)0) {                                               \
      fprintf(stderr, "Unexpected NULL from %s. Exiting.\n", loc);        \
      exit(EXIT_FAILURE);                                                 \
    }                                                                     \
  } while (0)

#if defined(__cplusplus)
}
#endif

#endif // OQS_COMMON_H
