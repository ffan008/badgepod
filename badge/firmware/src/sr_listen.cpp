// v1.2 local listen engine implementation. See sr_listen.h.
//
// Pipeline: AudioHub --(stereo ring)--> feed task --AFE--> fetch task
//           --(mono enhanced audio)--> MultiNet7 (Chinese) detect.
// The AFE also provides the VAD state used for the "someone is talking"
// expression. WakeNet is disabled: this is continuous command spotting,
// not wake-word interaction.
#include "sr_listen.h"
#include <Arduino.h>
#include <string.h>
#include <esp_heap_caps.h>
#include <freertos/FreeRTOS.h>
#include <freertos/task.h>
#include <freertos/semphr.h>

// esp-sr IDF interface (headers ship with the framework libs package)
#include "model_path.h"
#include "esp_afe_config.h"
#include "esp_afe_sr_iface.h"
#include "esp_afe_sr_models.h"
#include "esp_mn_iface.h"
#include "esp_mn_models.h"
#include "esp_mn_speech_commands.h"

static SrStatus g_status;

SrStatus &srStatus() { return g_status; }

// ---------------- speech commands ----------------
struct CmdPhrase { int id; const char *text; };
static const CmdPhrase kPhrases[] = {
  {1, "开始工作"},
  {2, "开始干活"},
  {2, "开工啦"},
  {3, "让我想想"},
  {4, "干得漂亮"},
  {4, "太棒了"},
  {5, "等一下"},
  {6, "休息一下"},
};

// ---------------- shared state ----------------
static srmodel_list_t *g_models = nullptr;
static char *g_mnName = nullptr;              // e.g. "mn7_cn"
static const esp_afe_sr_iface_t *g_afeHandle = nullptr;
static esp_afe_sr_data_t *g_afeData = nullptr;
static esp_mn_iface_t *g_mnHandle = nullptr;
static model_iface_data_t *g_mnData = nullptr;

static TaskHandle_t g_feedTask = nullptr;
static TaskHandle_t g_fetchTask = nullptr;
static volatile bool g_stopReq = false;
static volatile int g_tasksAlive = 0;

// Stereo ring buffer between AudioHub (producer) and the feed task.
static const int RING_FRAMES = 8192;          // 0.5 s of stereo audio
static int16_t *g_ring = nullptr;             // RING_FRAMES * 2 samples
static volatile int g_ringHead = 0;           // write index (frames)
static volatile int g_ringTail = 0;           // read index (frames)
static SemaphoreHandle_t g_ringMutex = nullptr;

bool srListenInit() {
  if (g_models) return g_status.available;
  g_models = esp_srmodel_init("model");
  if (!g_models) {
    Serial.println("SR: esp_srmodel_init('model') failed (partition missing/empty?)");
    return false;
  }
  Serial.printf("SR: %d model(s) in 'model' partition:", g_models->num);
  for (int i = 0; i < g_models->num; i++) Serial.printf(" %s", g_models->model_name[i]);
  Serial.println();
  g_mnName = esp_srmodel_filter(g_models, ESP_MN_PREFIX, ESP_MN_CHINESE);
  if (!g_mnName) {
    Serial.println("SR: no Chinese MultiNet model found");
    return false;
  }
  Serial.printf("SR: MultiNet model = %s\n", g_mnName);
  g_ring = (int16_t *)heap_caps_malloc(RING_FRAMES * 2 * sizeof(int16_t),
                                       MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
  g_ringMutex = xSemaphoreCreateMutex();
  if (!g_ring || !g_ringMutex) {
    Serial.println("SR: ring alloc failed");
    return false;
  }
  g_status.available = true;
  return true;
}

void srListenFeed(const int16_t *stereo, int frames) {
  if (!g_status.running || !g_ring) return;
  xSemaphoreTake(g_ringMutex, portMAX_DELAY);
  for (int i = 0; i < frames; i++) {
    int next = g_ringHead + 1;
    if (next >= RING_FRAMES) next = 0;
    if (next == g_ringTail) { g_status.dropFrames++; continue; }
    g_ring[g_ringHead * 2] = stereo[i * 2];
    g_ring[g_ringHead * 2 + 1] = stereo[i * 2 + 1];
    g_ringHead = next;
  }
  xSemaphoreGive(g_ringMutex);
}

static int ringFramesAvailable() {
  int h = g_ringHead, t = g_ringTail;
  int n = h - t;
  if (n < 0) n += RING_FRAMES;
  return n;
}

// ---------------- feed task ----------------
static void feedTask(void *arg) {
  (void)arg;
  g_tasksAlive++;
  const int chunkFrames = g_afeHandle->get_feed_chunksize(g_afeData);
  const int channels = g_afeHandle->get_channel_num(g_afeData);
  int16_t *buf = (int16_t *)malloc(chunkFrames * channels * sizeof(int16_t));
  Serial.printf("SR feed task: chunk=%d frames x %d ch\n", chunkFrames, channels);
  while (!g_stopReq) {
    if (ringFramesAvailable() < chunkFrames) { vTaskDelay(pdMS_TO_TICKS(10)); continue; }
    xSemaphoreTake(g_ringMutex, portMAX_DELAY);
    for (int i = 0; i < chunkFrames; i++) {
      buf[i * channels] = g_ring[g_ringTail * 2];
      if (channels > 1) buf[i * channels + 1] = g_ring[g_ringTail * 2 + 1];
      int next = g_ringTail + 1;
      if (next >= RING_FRAMES) next = 0;
      g_ringTail = next;
    }
    xSemaphoreGive(g_ringMutex);
    g_afeHandle->feed(g_afeData, buf);
  }
  free(buf);
  g_tasksAlive--;
  g_feedTask = nullptr;
  vTaskDelete(nullptr);
}

// ---------------- fetch / detect task ----------------
static void fetchTask(void *arg) {
  (void)arg;
  g_tasksAlive++;
  const int mnChunk = g_mnHandle->get_samp_chunksize(g_mnData);
  int16_t *mnBuf = (int16_t *)malloc(mnChunk * sizeof(int16_t));
  int mnFill = 0;
  Serial.printf("SR fetch task: MN chunk=%d samples\n", mnChunk);
  while (!g_stopReq) {
    afe_fetch_result_t *res = g_afeHandle->fetch(g_afeData);
    if (!res || res->ret_value != ESP_OK) continue;
    g_status.volumeDb = res->data_volume;
    if (res->vad_state == VAD_SPEECH) {
      g_status.speech = true;
      g_status.lastSpeechMs = millis();
    } else {
      g_status.speech = false;
    }
    // Accumulate enhanced mono audio and run MultiNet per chunk.
    const int16_t *pcm = res->data;
    int samples = res->data_size / (int)sizeof(int16_t);
    for (int i = 0; i < samples; i++) {
      mnBuf[mnFill++] = pcm[i];
      if (mnFill < mnChunk) continue;
      mnFill = 0;
      esp_mn_state_t st = g_mnHandle->detect(g_mnData, mnBuf);
      if (st == ESP_MN_STATE_DETECTED) {
        esp_mn_results_t *r = g_mnHandle->get_results(g_mnData);
        if (r && r->num > 0) {
          g_status.pendingCommand = r->command_id[0];
          g_status.commandMs = millis();
          Serial.printf("SR command id=%d prob=%.2f str=%s\n",
                        r->command_id[0], (double)r->prob[0], r->string);
        }
        g_mnHandle->clean(g_mnData);
      } else if (st == ESP_MN_STATE_TIMEOUT) {
        g_mnHandle->clean(g_mnData);  // restart the detection window
      }
    }
  }
  free(mnBuf);
  g_tasksAlive--;
  g_fetchTask = nullptr;
  vTaskDelete(nullptr);
}

bool srListenStart() {
  if (!g_status.available || g_status.running) return g_status.running;
  if (!g_models || !g_mnName) return false;

  // --- AFE ---
  afe_config_t *cfg = afe_config_init("MM", g_models, AFE_TYPE_SR, AFE_MODE_LOW_COST);
  if (!cfg) { Serial.println("SR: afe_config_init failed"); return false; }
  cfg->wakenet_init = false;        // continuous MultiNet, no wake word
  cfg->aec_init = false;            // no playback reference channel
  cfg->fixed_first_channel = true;  // deterministic channel selection
  cfg->fixed_output_channel = true;
  cfg->memory_alloc_mode = AFE_MEMORY_ALLOC_MORE_PSRAM;
  g_afeHandle = esp_afe_handle_from_config(cfg);
  if (!g_afeHandle) { Serial.println("SR: esp_afe_handle_from_config failed"); return false; }
  g_afeData = g_afeHandle->create_from_config(cfg);
  if (!g_afeData) { Serial.println("SR: AFE create failed"); return false; }
  g_afeHandle->print_pipeline(g_afeData);

  // --- MultiNet (Chinese) ---
  g_mnHandle = esp_mn_handle_from_name(g_mnName);
  if (!g_mnHandle) { Serial.println("SR: esp_mn_handle_from_name failed"); goto fail; }
  g_mnData = g_mnHandle->create(g_mnName, 6000);
  if (!g_mnData) { Serial.println("SR: MultiNet create failed"); goto fail; }
  if (esp_mn_commands_alloc(g_mnHandle, g_mnData) != ESP_OK) {
    Serial.println("SR: esp_mn_commands_alloc failed");
    goto fail;
  }
  for (size_t i = 0; i < sizeof(kPhrases) / sizeof(kPhrases[0]); i++)
    esp_mn_commands_add(kPhrases[i].id, kPhrases[i].text);
  {
    esp_mn_error_t *err = esp_mn_commands_update();
    if (err) {
      Serial.printf("SR: %d phrase(s) rejected by MultiNet\n", err->num);
      for (int i = 0; i < err->num; i++)
        Serial.printf("SR:   rejected: %s\n", err->phrases[i]->string);
    }
  }
  esp_mn_commands_print();

  // --- tasks ---
  g_stopReq = false;
  g_ringHead = g_ringTail = 0;
  g_status.speech = false;
  g_status.pendingCommand = 0;
  xTaskCreatePinnedToCore(feedTask, "sr_feed", 4096, nullptr, 5, &g_feedTask, 0);
  xTaskCreatePinnedToCore(fetchTask, "sr_fetch", 8192, nullptr, 5, &g_fetchTask, 0);
  g_status.running = true;
  Serial.println("SR listen started");
  return true;

fail:
  if (g_mnData) { g_mnHandle->destroy(g_mnData); g_mnData = nullptr; }
  if (g_afeData) { g_afeHandle->destroy(g_afeData); g_afeData = nullptr; }
  return false;
}

void srListenStop() {
  if (!g_status.running) return;
  g_stopReq = true;
  // fetch() can block up to ~2 s inside AFE; wait for both tasks to exit
  // before destroying the handles they use.
  uint32_t t0 = millis();
  while (g_tasksAlive > 0 && millis() - t0 < 4000) vTaskDelay(pdMS_TO_TICKS(20));
  if (g_tasksAlive > 0) Serial.println("SR: WARNING tasks did not exit in time");
  g_status.running = false;
  g_status.speech = false;
  esp_mn_commands_free();
  if (g_mnData) { g_mnHandle->destroy(g_mnData); g_mnData = nullptr; }
  if (g_afeData) { g_afeHandle->destroy(g_afeData); g_afeData = nullptr; }
  Serial.println("SR listen stopped");
}
