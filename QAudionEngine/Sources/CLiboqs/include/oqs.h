#ifndef OQS_H
#define OQS_H

#include <stddef.h>
#include <stdint.h>

// ML-KEM-1024 constants (NIST FIPS 203)
#define OQS_KEM_ml_kem_1024_length_public_key 1568
#define OQS_KEM_ml_kem_1024_length_secret_key 3168
#define OQS_KEM_ml_kem_1024_length_ciphertext 1568
#define OQS_KEM_ml_kem_1024_length_shared_secret 32

// Return codes
#define OQS_SUCCESS 0
#define OQS_ERROR -1

// KEM structure
typedef struct {
    const char *method_name;
    size_t length_public_key;
    size_t length_secret_key;
    size_t length_ciphertext;
    size_t length_shared_secret;
} OQS_KEM;

// API functions (stubs - real implementation in liboqs)
OQS_KEM *OQS_KEM_new(const char *method_name);
void OQS_KEM_free(OQS_KEM *kem);
int OQS_KEM_keypair(const OQS_KEM *kem, uint8_t *public_key, uint8_t *secret_key);
int OQS_KEM_encaps(const OQS_KEM *kem, uint8_t *ciphertext, uint8_t *shared_secret, const uint8_t *public_key);
int OQS_KEM_decaps(const OQS_KEM *kem, uint8_t *shared_secret, const uint8_t *ciphertext, const uint8_t *secret_key);
void OQS_MEM_cleanse(void *ptr, size_t len);

#endif // OQS_H
