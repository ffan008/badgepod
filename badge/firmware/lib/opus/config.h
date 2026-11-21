/* Minimal libopus config for ESP32-S3 (floating point, generic C, no asm) */
#ifndef OPUS_CONFIG_H
#define OPUS_CONFIG_H

#define OPUS_BUILD 1
#define USE_ALLOCA 1

/* Floating-point build (ESP32-S3 has an FPU) */
/* #undef FIXED_POINT */

#define HAVE_LRINT 1
#define HAVE_LRINTF 1

#endif
