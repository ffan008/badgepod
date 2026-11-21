#pragma once
// v1.2 local listen engine: ESP-SR AFE + Chinese MultiNet7, used directly
// through the esp-sr IDF interface that ships inside the Arduino
// framework's esp32s3 libs package. The framework's ESP_SR Arduino
// wrapper is NOT used: it hard-filters MultiNet to ESP_MN_ENGLISH and
// its bundled srmodels.bin only contains the English model.
//
// The engine consumes stereo 16 kHz frames pushed by the AudioHub task
// (srListenFeed) and publishes results through srStatus():
//   - speech / lastSpeechMs : AFE VAD state (drives the "listening" face)
//   - pendingCommand        : command_id of the last matched phrase
//                             (consumer reads it and resets it to 0)
#include <stdint.h>
#include <stdbool.h>

struct SrStatus {
  volatile bool available;        // srListenInit() succeeded
  volatile bool running;          // feed/fetch tasks are alive
  volatile bool speech;           // latest AFE VAD state (true = speech)
  volatile uint32_t lastSpeechMs; // millis() of the last VAD speech report
  volatile int pendingCommand;    // matched command_id, 0 = none pending
  volatile uint32_t commandMs;    // millis() when the command fired
  volatile float volumeDb;        // last AFE fetch data_volume (dBFS)
  volatile uint32_t dropFrames;   // ring-buffer overflow counter (debug)
};

// Command IDs (multiple phrases may share one ID):
//   1 = working      "开始工作"
//   2 = making       "开始干活" / "开工啦"
//   3 = connecting   "让我想想"          (thinking placeholder)
//   4 = celebration  "干得漂亮" / "太棒了"
//   5 = waiting      "等一下"
//   6 = idle         "休息一下"

// One-time model load from the "model" partition. Safe to call once at
// boot; the model list (flash mmap) is kept for the process lifetime.
bool srListenInit();

// Create AFE + MultiNet + feed/fetch tasks. Returns false if the engine
// is unavailable or already running.
bool srListenStart();

// Stop tasks and destroy AFE + MultiNet (frees their RAM). Used while
// recording so the recorder owns the audio path and memory exclusively.
void srListenStop();

// Push one block of interleaved stereo frames (16 kHz) from AudioHub.
// Samples are dropped silently when the engine is not running.
void srListenFeed(const int16_t *stereo, int frames);

SrStatus &srStatus();
