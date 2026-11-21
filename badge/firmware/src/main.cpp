// Muse badge firmware v1.1 — Waveshare ESP32-S3-Touch-AMOLED-1.75C
//
// v1: mascot MJPEG animations on the 466x466 AMOLED, BOOT short press =
//     next state, BOOT long press = record (WAV), AXP2101 battery %.
// v1.1 changes:
//  - Recording is Opus (16 kHz mono, 16 kbps) in an Ogg container (.ogg),
//    stored locally on LittleFS as the master copy (up to ~2 h).
//  - Record-and-stream: while recording, the Ogg stream is also pushed
//    over Wi-Fi (TCP) to a receiver on the Mac (UDP broadcast discovery).
//    Local copy is always complete; the stream is a live copy.
//  - Screen turns off 3 s into a recording (BOOT short press = peek 3 s,
//    long press = stop) to save power and stay discreet.
//  - Wi-Fi provisioning: first boot (or BOOT held at power-on) opens the
//    "MuseBadge-Setup" AP with a captive form; credentials live in NVS.
//
// Pin map (from Waveshare board_config):
//  LCD QSPI: CS12 SCLK38 SDIO 4/5/6/7, RST1 | I2C: SDA15 SCL14
//  ES7210: BCLK9 LRCK45 DIN10 MCLK16 | BOOT button: GPIO0
#include <Arduino.h>
#include <Wire.h>
#include <LittleFS.h>
#include <WiFi.h>
#include <WiFiUdp.h>
#include <WebServer.h>
#include <Preferences.h>
#include <driver/i2s.h>
#include <Arduino_GFX_Library.h>
#include <JPEGDEC.h>
#include <XPowersLib.h>
#include <opus.h>
#include "es7210_min.h"

// ---------------- Pins ----------------
static const int LCD_CS = 12, LCD_SCLK = 38, LCD_RST = 1;
static const int LCD_D0 = 4, LCD_D1 = 5, LCD_D2 = 6, LCD_D3 = 7;
static const int IIC_SDA = 15, IIC_SCL = 14;
static const int PIN_BCLK = 9, PIN_LRCK = 45, PIN_DIN = 10, PIN_MCLK = 16;
static const int PIN_BOOT = 0;

// ---------------- Avatar states ----------------
struct StateDef { const char *file; const char *label; };
static const StateDef kStates[] = {
  {"/idle.avi",           "IDLE"},
  {"/working.avi",        "WORKING"},
  {"/making.avi",         "MAKING"},
  {"/connecting.avi",     "CONNECTING"},
  {"/celebration.avi",    "CELEBRATE"},
  {"/waiting-helper.avi", "WAITING"},
};
static const int kNumStates = sizeof(kStates) / sizeof(kStates[0]);
static int g_state = 0;

// ---------------- Globals ----------------
Arduino_DataBus *bus = new Arduino_ESP32QSPI(LCD_CS, LCD_SCLK, LCD_D0, LCD_D1, LCD_D2, LCD_D3);
Arduino_CO5300 *gfx = new Arduino_CO5300(bus, LCD_RST, 0, 466, 466, 6, 0, 0, 0);
JPEGDEC jpeg;
XPowersAXP2101 pmu;
ES7210 codec;
bool g_pmuOk = false;

// Loaded clip in PSRAM
static uint8_t *g_clip = nullptr;
static size_t g_clipLen = 0;
static uint32_t g_frameOff[512];
static uint32_t g_frameSize[512];
static int g_frameCount = 0;

// ---------------- Recording / streaming constants ----------------
static const uint32_t REC_SAMPLE_RATE = 16000;
static const uint32_t REC_MAX_SEC = 7200;          // 2 h at 16 kbps Opus
static const uint32_t REC_MIN_FREE = 1536 * 1024;  // stop if LittleFS free < 1.5 MB
static const int OPUS_FRAME = 320;                 // 20 ms @ 16 kHz
static const int OPUS_BITRATE = 16000;
static const uint16_t DISC_PORT = 47800;           // UDP discovery
static const size_t FIFO_CAP = 1024 * 1024;        // stream backlog cap (PSRAM)

static bool g_recording = false;
static File g_recFile;
static char g_recName[32] = "";
static uint32_t g_recStartMs = 0;
static uint32_t g_sessionId = 0;
static OpusEncoder *g_opus = nullptr;

// Screen-off-while-recording state
static bool g_screenOff = false;
static uint32_t g_showUntilMs = 0;

// Wi-Fi
static bool g_apMode = false;
static WebServer *g_server = nullptr;
static Preferences g_prefs;

// ---------------- Stream FIFO (PSRAM chunks) ----------------
struct Chunk { uint8_t *data; size_t len; Chunk *next; };
static Chunk *g_fifoHead = nullptr, *g_fifoTail = nullptr;
static size_t g_fifoBytes = 0;
static SemaphoreHandle_t g_fifoMutex = nullptr;
static volatile bool g_streamOverflow = false;

static void fifoPush(const uint8_t *data, size_t len) {
  if (g_streamOverflow) return;
  uint8_t *copy = (uint8_t *)ps_malloc(len);
  if (!copy) { g_streamOverflow = true; return; }
  memcpy(copy, data, len);
  Chunk *c = (Chunk *)malloc(sizeof(Chunk));
  c->data = copy; c->len = len; c->next = nullptr;
  xSemaphoreTake(g_fifoMutex, portMAX_DELAY);
  if (g_fifoBytes + len > FIFO_CAP) { g_streamOverflow = true; free(copy); free(c); }
  else {
    if (g_fifoTail) g_fifoTail->next = c; else g_fifoHead = c;
    g_fifoTail = c; g_fifoBytes += len;
  }
  xSemaphoreGive(g_fifoMutex);
  if (g_streamOverflow) Serial.println("stream FIFO overflow, live copy incomplete");
}

// Returns nullptr when empty. Caller frees data + chunk.
static Chunk *fifoPop() {
  xSemaphoreTake(g_fifoMutex, portMAX_DELAY);
  Chunk *c = g_fifoHead;
  if (c) {
    g_fifoHead = c->next;
    if (!g_fifoHead) g_fifoTail = nullptr;
    g_fifoBytes -= c->len;
  }
  xSemaphoreGive(g_fifoMutex);
  return c;
}

// ---------------- Ogg / Opus writer ----------------
// Writes a standard Ogg Opus stream to the local file and mirrors every
// byte into the stream FIFO. One muxer => local file and live copy are
// byte-identical up to whatever the FIFO managed to carry.
class OggOpusWriter {
 public:
  void begin(uint32_t serial) {
    serial_ = serial; seq_ = 0; granule_ = 0; packetsInPage_ = 0; pageLen_ = 0;
    writeHeaderPages();
  }
  // Queue one encoded Opus packet (20 ms => granule step 960 @48k units).
  void writePacket(const uint8_t *data, size_t len) {
    size_t off = 0;
    // Ogg segmenting: 255-byte lacing values + remainder
    size_t lacing = len / 255 + 1;
    if (packetsInPage_ > 0 && (pageLen_ + len > 4096 || packetsInPage_ + lacing > 200)) flushPage(false);
    memcpy(pageBuf_ + pageLen_, data, len); pageLen_ += len;
    // remember segment sizes in a side buffer
    size_t rem = len;
    while (rem >= 255) { segBuf_[segCount_++] = 255; rem -= 255; }
    segBuf_[segCount_++] = (uint8_t)rem;
    (void)off;
    granule_ += 960;
    packetsInPage_++;
    if (packetsInPage_ >= 40) flushPage(false);  // ~0.8 s per page
  }
  void finish() { flushPage(true); }
  uint64_t granule() const { return granule_; }

 private:
  uint32_t serial_ = 0, seq_ = 0;
  uint64_t granule_ = 0;
  uint8_t pageBuf_[4096 + 512];
  size_t pageLen_ = 0;
  uint8_t segBuf_[255];
  int segCount_ = 0;
  int packetsInPage_ = 0;

  static uint32_t crcTable_[256];
  static bool crcReady_;
  static uint32_t oggCrc(const uint8_t *buf, size_t len) {
    if (!crcReady_) {
      for (uint32_t i = 0; i < 256; i++) {
        uint32_t r = i << 24;
        for (int j = 0; j < 8; j++) r = (r & 0x80000000) ? ((r << 1) ^ 0x04C11DB7) : (r << 1);
        crcTable_[i] = r;
      }
      crcReady_ = true;
    }
    uint32_t crc = 0;
    for (size_t i = 0; i < len; i++) crc = (crc << 8) ^ crcTable_[((crc >> 24) ^ buf[i]) & 0xFF];
    return crc;
  }

  void emit(const uint8_t *data, size_t len) {
    if (g_recFile) g_recFile.write(data, len);
    fifoPush(data, len);
  }

  void writePage(const uint8_t *payload, size_t plen, const uint8_t *segs, int nsegs,
                 uint64_t granule, bool bos, bool eos) {
    uint8_t hdr[27 + 255];
    memcpy(hdr, "OggS", 4);
    hdr[4] = 0;
    hdr[5] = (bos ? 0x02 : 0x00) | (eos ? 0x04 : 0x00);
    for (int i = 0; i < 8; i++) hdr[6 + i] = (uint8_t)(granule >> (8 * i));
    for (int i = 0; i < 4; i++) hdr[14 + i] = (uint8_t)(serial_ >> (8 * i));
    for (int i = 0; i < 4; i++) hdr[18 + i] = (uint8_t)(seq_ >> (8 * i));
    hdr[22] = hdr[23] = hdr[24] = hdr[25] = 0;  // CRC filled below
    hdr[26] = (uint8_t)nsegs;
    memcpy(hdr + 27, segs, nsegs);
    size_t total = 27 + nsegs + plen;
    uint8_t *page = (uint8_t *)malloc(total);
    memcpy(page, hdr, 27 + nsegs);
    memcpy(page + 27 + nsegs, payload, plen);
    uint32_t crc = oggCrc(page, total);
    page[22] = crc & 0xFF; page[23] = (crc >> 8) & 0xFF;
    page[24] = (crc >> 16) & 0xFF; page[25] = (crc >> 24) & 0xFF;
    emit(page, total);
    free(page);
    seq_++;
  }

  void writeHeaderPages() {
    // OpusHead (RFC 7845): version 1, 1 channel, pre-skip 312, rate 48000
    uint8_t head[19];
    memcpy(head, "OpusHead", 8);
    head[8] = 1; head[9] = 1;
    head[10] = 312 & 0xFF; head[11] = 312 >> 8;
    head[12] = 0x80; head[13] = 0xBB; head[14] = 0x00; head[15] = 0x00;  // 48000
    head[16] = 0; head[17] = 0; head[18] = 0;
    uint8_t seg = 19;
    writePage(head, 19, &seg, 1, 0, true, false);
    // OpusTags: vendor only, no user comments
    uint8_t tags[24];
    memcpy(tags, "OpusTags", 8);
    tags[8] = 9; tags[9] = 0; tags[10] = 0; tags[11] = 0;
    memcpy(tags + 12, "MuseBadge", 9);
    tags[21] = 0; tags[22] = 0; tags[23] = 0;
    seg = 24;
    writePage(tags, 24, &seg, 1, 0, false, false);
  }

  void flushPage(bool eos) {
    if (packetsInPage_ == 0 && !eos) return;
    writePage(pageBuf_, pageLen_, segBuf_, segCount_, granule_, false, eos);
    pageLen_ = 0; segCount_ = 0; packetsInPage_ = 0;
  }
};
uint32_t OggOpusWriter::crcTable_[256];
bool OggOpusWriter::crcReady_ = false;
static OggOpusWriter g_writer;

// ---------------- Streamer task (core 0) ----------------
// Discovers the Mac receiver by UDP broadcast, connects over TCP and
// drains the FIFO. The local .ogg file is the master; this live copy is
// best-effort. Preamble line per connection: "MBR1 <session> <cont>\n"
// (cont=1 means the stream continues a session whose headers were
// already sent; the receiver resyncs on Ogg page boundaries).
static volatile bool g_streamerConnected = false;
static bool g_sessionStreamedOnce = false;

static void fifoClear() {
  Chunk *c;
  while ((c = fifoPop()) != nullptr) { free(c->data); free(c); }
  g_streamOverflow = false;
}

static void streamerTask(void *arg) {
  (void)arg;
  WiFiUDP udp;
  udp.begin(DISC_PORT);
  WiFiClient client;
  uint32_t activeSession = 0;
  for (;;) {
    if (g_apMode || WiFi.status() != WL_CONNECTED) {
      if (client.connected()) client.stop();
      g_streamerConnected = false;
      vTaskDelay(pdMS_TO_TICKS(500));
      continue;
    }
    if (g_sessionId != activeSession) {
      if (client.connected()) client.stop();
      g_streamerConnected = false;
      activeSession = g_sessionId;
      g_sessionStreamedOnce = false;
    }
    if (!client.connected()) {
      if (!g_recording) { vTaskDelay(pdMS_TO_TICKS(300)); continue; }
      // Discovery round: broadcast, wait ~0.9 s for "MUSEREC <port>"
      IPAddress recIp;
      uint16_t recPort = 0;
      udp.beginPacket(IPAddress(255, 255, 255, 255), DISC_PORT);
      udp.print("MUSEBADGE_DISC");
      udp.endPacket();
      uint32_t t0 = millis();
      while (millis() - t0 < 900 && recPort == 0) {
        int sz = udp.parsePacket();
        if (sz > 0) {
          char buf[64];
          int n = udp.read(buf, sizeof(buf) - 1);
          if (n > 0) {
            buf[n] = 0;
            int port = 0;
            if (sscanf(buf, "MUSEREC %d", &port) == 1 && port > 0) {
              recIp = udp.remoteIP();
              recPort = (uint16_t)port;
            }
          }
        }
        vTaskDelay(pdMS_TO_TICKS(20));
      }
      if (recPort && client.connect(recIp, recPort)) {
        char pre[48];
        snprintf(pre, sizeof(pre), "MBR1 %08lx %d\n",
                 (unsigned long)activeSession, g_sessionStreamedOnce ? 1 : 0);
        client.print(pre);
        g_sessionStreamedOnce = true;
        g_streamerConnected = true;
        Serial.printf("stream -> %s:%u (session %08lx)\n",
                      recIp.toString().c_str(), recPort, (unsigned long)activeSession);
      } else {
        vTaskDelay(pdMS_TO_TICKS(1500));
      }
      continue;
    }
    // Connected: drain FIFO
    bool err = false;
    Chunk *c;
    while ((c = fifoPop()) != nullptr) {
      size_t sent = client.write(c->data, c->len);
      free(c->data);
      free(c);
      if (sent == 0 || !client.connected()) { err = true; break; }
    }
    if (err) {
      client.stop();
      g_streamerConnected = false;
      vTaskDelay(pdMS_TO_TICKS(500));
      continue;
    }
    if (!g_recording && g_fifoHead == nullptr) {
      client.stop();  // session fully delivered
      g_streamerConnected = false;
    }
    vTaskDelay(pdMS_TO_TICKS(50));
  }
}

// ---------------- Wi-Fi provisioning ----------------
static void wifiSetup() {
  g_prefs.begin("badge", false);
  // BOOT held at power-on for ~2 s forgets the saved network.
  if (digitalRead(PIN_BOOT) == LOW) {
    uint32_t t0 = millis();
    while (digitalRead(PIN_BOOT) == LOW && millis() - t0 < 2500) delay(10);
    if (millis() - t0 >= 2000) {
      g_prefs.remove("ssid");
      g_prefs.remove("pass");
      Serial.println("WiFi credentials cleared");
    }
  }
  String ssid = g_prefs.getString("ssid", "");
  String pass = g_prefs.getString("pass", "");
  if (ssid.length() > 0) {
    WiFi.mode(WIFI_STA);
    WiFi.begin(ssid.c_str(), pass.c_str());
    uint32_t t0 = millis();
    while (WiFi.status() != WL_CONNECTED && millis() - t0 < 10000) delay(100);
    if (WiFi.status() == WL_CONNECTED)
      Serial.printf("WiFi connected: %s\n", WiFi.localIP().toString().c_str());
    else
      Serial.println("WiFi not connected yet (auto-retry in background)");
  } else {
    g_apMode = true;
    WiFi.mode(WIFI_AP);
    WiFi.softAP("MuseBadge-Setup");
    g_server = new WebServer(80);
    g_server->on("/", []() {
      g_server->send(200, "text/html",
        "<html><body style='font-family:sans-serif;margin:2em'>"
        "<h2>MuseBadge Wi-Fi setup</h2>"
        "<form method='POST' action='/save'>"
        "Wi-Fi name (SSID)<br><input name='ssid' style='font-size:1.2em'><br><br>"
        "Password<br><input name='pass' type='password' style='font-size:1.2em'><br><br>"
        "<button type='submit' style='font-size:1.2em'>Save &amp; restart</button>"
        "</form></body></html>");
    });
    g_server->on("/save", HTTP_POST, []() {
      String ssid = g_server->arg("ssid");
      String pass = g_server->arg("pass");
      if (ssid.length() > 0) {
        g_prefs.putString("ssid", ssid);
        g_prefs.putString("pass", pass);
        g_server->send(200, "text/html", "<html><body>Saved. The badge is restarting.</body></html>");
        delay(600);
        ESP.restart();
      } else {
        g_server->send(400, "text/plain", "SSID required");
      }
    });
    g_server->begin();
    Serial.printf("Setup AP 'MuseBadge-Setup' at %s\n", WiFi.softAPIP().toString().c_str());
  }
}

// ---------------- UI helpers ----------------
static int batteryPct() {
  if (!g_pmuOk || !pmu.isBatteryConnect()) return -1;
  return pmu.getBatteryPercent();
}

static void screenOn() {
  if (!g_screenOff) return;
  gfx->setBrightness(200);
  g_screenOff = false;
}

static void screenOff() {
  if (g_screenOff) return;
  gfx->fillScreen(RGB565_BLACK);
  gfx->setBrightness(0);
  g_screenOff = true;
}

static void showSplash(const char *label) {
  screenOn();
  gfx->fillScreen(RGB565_BLACK);
  gfx->setTextColor(RGB565_CYAN);
  gfx->setTextSize(4);
  gfx->setCursor(120, 200);
  gfx->print(label);
  int b = batteryPct();
  if (b >= 0) {
    gfx->setTextSize(3);
    gfx->setTextColor(RGB565_WHITE);
    gfx->setCursor(170, 280);
    gfx->printf("BAT %d%%", b);
  }
  delay(700);
}

static void showSetupScreen() {
  gfx->fillScreen(RGB565_BLACK);
  gfx->setTextColor(RGB565_CYAN);
  gfx->setTextSize(4);
  gfx->setCursor(150, 150);
  gfx->print("SETUP");
  gfx->setTextColor(RGB565_WHITE);
  gfx->setTextSize(3);
  gfx->setCursor(60, 230);
  gfx->print("WiFi: MuseBadge-Setup");
  gfx->setCursor(60, 280);
  gfx->print("Open 192.168.4.1");
}

static void showRecScreen(uint32_t elapsedSec) {
  gfx->fillScreen(RGB565_BLACK);
  gfx->fillCircle(233, 170, 46, RGB565_RED);
  gfx->setTextColor(RGB565_WHITE);
  gfx->setTextSize(5);
  gfx->setCursor(150, 260);
  gfx->printf("%lus", (unsigned long)elapsedSec);
  gfx->setTextSize(3);
  gfx->setCursor(110, 330);
  gfx->print("REC - hold BOOT to stop");
  gfx->setTextSize(2);
  gfx->setCursor(110, 370);
  gfx->print(WiFi.status() == WL_CONNECTED && g_streamerConnected ? "streaming" : "local only");
}

// ---------------- Button ----------------
// Returns: 0 none, 1 short press, 2 long press (fires once while held)
static int pollButton() {
  static bool wasDown = false;
  static uint32_t downAt = 0;
  static bool longFired = false;
  bool down = (digitalRead(PIN_BOOT) == LOW);
  uint32_t now = millis();
  if (down && !wasDown) { downAt = now; longFired = false; }
  if (down && !longFired && now - downAt >= 1200) { longFired = true; wasDown = down; return 2; }
  if (!down && wasDown && !longFired) { wasDown = down; return 1; }
  wasDown = down;
  return 0;
}

// ---------------- Recording (Opus / Ogg) ----------------
static void startRecording() {
  if (!g_streamerConnected) fifoClear();
  int idx = 0;
  do { snprintf(g_recName, sizeof(g_recName), "/rec_%03d.ogg", idx++); }
  while (LittleFS.exists(g_recName) && idx < 1000);
  g_recFile = LittleFS.open(g_recName, "w");
  if (!g_recFile) { Serial.println("rec open failed"); return; }
  if (!g_opus) {
    int err = 0;
    g_opus = opus_encoder_create(REC_SAMPLE_RATE, 1, OPUS_APPLICATION_VOIP, &err);
    if (!g_opus || err != OPUS_OK) { Serial.println("opus create failed"); g_recFile.close(); return; }
    opus_encoder_ctl(g_opus, OPUS_SET_BITRATE(OPUS_BITRATE));
    opus_encoder_ctl(g_opus, OPUS_SET_COMPLEXITY(5));
    opus_encoder_ctl(g_opus, OPUS_SET_SIGNAL(OPUS_SIGNAL_VOICE));
  }
  g_sessionId = esp_random();
  g_writer.begin(g_sessionId);  // Ogg header pages -> file + FIFO
  codec.start();
  i2s_start(I2S_NUM_1);
  g_recording = true;
  g_recStartMs = millis();
  screenOn();
  showRecScreen(0);
  g_showUntilMs = millis() + 3000;  // screen goes dark 3 s in
  Serial.printf("REC start %s session %08lx\n", g_recName, (unsigned long)g_sessionId);
}

static void stopRecording() {
  i2s_stop(I2S_NUM_1);
  codec.stop();
  g_writer.finish();  // final page with EOS flag
  g_recFile.flush();
  g_recFile.close();
  g_recording = false;
  screenOn();
  Serial.printf("REC stop %s\n", g_recName);
  showSplash(kStates[g_state].label);
}

static void recordLoop() {
  static int16_t stereo[2048];        // 1024 stereo frames per read
  static int16_t frame[OPUS_FRAME];   // mono accumulator (20 ms)
  static int frameFill = 0;
  size_t read = 0;
  i2s_read(I2S_NUM_1, stereo, sizeof(stereo), &read, portMAX_DELAY);
  int frames = (int)(read / 4);
  for (int i = 0; i < frames; i++) {
    int32_t m = ((int32_t)stereo[2 * i] + stereo[2 * i + 1]) / 2;
    frame[frameFill++] = (int16_t)m;
    if (frameFill == OPUS_FRAME) {
      uint8_t out[512];
      int n = opus_encode(g_opus, frame, OPUS_FRAME, out, sizeof(out));
      if (n > 0) g_writer.writePacket(out, (size_t)n);
      frameFill = 0;
    }
  }
  static uint32_t lastFlush = 0;
  if (millis() - lastFlush > 5000) { lastFlush = millis(); g_recFile.flush(); }

  uint32_t now = millis();
  uint32_t elapsed = (now - g_recStartMs) / 1000;
  if (!g_screenOff && now > g_showUntilMs) screenOff();
  if (!g_screenOff) {
    static uint32_t lastShown = 0xFFFFFFFF;
    if (elapsed != lastShown) { lastShown = elapsed; showRecScreen(elapsed); }
  }
  int act = pollButton();
  if (act == 2) { stopRecording(); return; }
  if (act == 1 && g_screenOff) {  // peek: show REC screen for 3 s
    screenOn();
    showRecScreen(elapsed);
    g_showUntilMs = now + 3000;
  }
  if (elapsed >= REC_MAX_SEC) { stopRecording(); return; }
  if (LittleFS.totalBytes() - LittleFS.usedBytes() < REC_MIN_FREE) {
    Serial.println("LittleFS nearly full, stopping recording");
    stopRecording();
  }
}

// ---------------- JPEG draw callback ----------------
static int jpegDraw(JPEGDRAW *pDraw) {
  gfx->draw16bitRGBBitmap(pDraw->x, pDraw->y, pDraw->pPixels, pDraw->iWidth, pDraw->iHeight);
  return 1;
}

// ---------------- AVI (MJPEG) parsing ----------------
static uint32_t rd32(const uint8_t *p) {
  return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

static bool loadClip(const char *path) {
  File f = LittleFS.open(path, "r");
  if (!f) { Serial.printf("open %s failed\n", path); return false; }
  size_t len = f.size();
  uint8_t *buf = (uint8_t *)ps_malloc(len);
  if (!buf) { Serial.println("ps_malloc failed"); f.close(); return false; }
  f.read(buf, len);
  f.close();
  if (memcmp(buf, "RIFF", 4) != 0 || memcmp(buf + 8, "AVI ", 4) != 0) {
    Serial.println("not an AVI"); free(buf); return false;
  }
  size_t moviStart = 0, moviEnd = 0;
  for (size_t p = 12; p + 8 <= len;) {
    uint32_t sz = rd32(buf + p + 4);
    if (memcmp(buf + p, "LIST", 4) == 0 && memcmp(buf + p + 8, "movi", 4) == 0) {
      moviStart = p + 12;
      moviEnd = p + 8 + sz;
      if (moviEnd > len) moviEnd = len;
      break;
    }
    p += 8 + sz + (sz & 1);
  }
  if (!moviStart) { Serial.println("no movi list"); free(buf); return false; }
  int n = 0;
  for (size_t p = moviStart; p + 8 <= moviEnd && n < 512;) {
    uint32_t sz = rd32(buf + p + 4);
    const uint8_t *id = buf + p;
    if ((id[3] == 'c' || id[3] == 'b') && id[2] == 'd' && sz > 4 &&
        buf[p + 8] == 0xFF && buf[p + 9] == 0xD8) {
      g_frameOff[n] = p + 8;
      g_frameSize[n] = sz;
      n++;
    }
    if (memcmp(id, "LIST", 4) == 0) { p += 12; continue; }
    p += 8 + sz + (sz & 1);
  }
  if (g_clip) free(g_clip);
  g_clip = buf; g_clipLen = len; g_frameCount = n;
  Serial.printf("clip %s: %d frames, %u bytes\n", path, n, (unsigned)len);
  return n > 0;
}

// ---------------- Setup ----------------
void setup() {
  Serial.begin(115200);
  delay(300);
  Serial.println("Muse badge v1.1");
  Wire.begin(IIC_SDA, IIC_SCL);
  pinMode(PIN_BOOT, INPUT_PULLUP);
  g_fifoMutex = xSemaphoreCreateMutex();

  g_pmuOk = pmu.begin(Wire, AXP2101_SLAVE_ADDRESS, IIC_SDA, IIC_SCL);
  Serial.printf("PMU %s\n", g_pmuOk ? "ok" : "not found");

  if (!gfx->begin()) Serial.println("gfx begin failed");
  gfx->setBrightness(200);
  gfx->fillScreen(RGB565_BLACK);

  if (!LittleFS.begin(false, "/littlefs", 10, "storage")) {
    gfx->setTextColor(RGB565_RED); gfx->setTextSize(3);
    gfx->setCursor(60, 220); gfx->print("LittleFS mount failed");
    Serial.println("LittleFS mount failed (upload fs image first)");
  }

  wifiSetup();
  xTaskCreatePinnedToCore(streamerTask, "streamer", 8192, nullptr, 1, nullptr, 0);

  if (!codec.begin(Wire)) Serial.println("ES7210 not found");
  i2s_config_t cfg = {};
  cfg.mode = (i2s_mode_t)(I2S_MODE_MASTER | I2S_MODE_RX);
  cfg.sample_rate = REC_SAMPLE_RATE;
  cfg.bits_per_sample = I2S_BITS_PER_SAMPLE_16BIT;
  cfg.channel_format = I2S_CHANNEL_FMT_RIGHT_LEFT;
  cfg.communication_format = I2S_COMM_FORMAT_STAND_I2S;
  cfg.intr_alloc_flags = ESP_INTR_FLAG_LEVEL1;
  cfg.dma_buf_count = 8;
  cfg.dma_buf_len = 256;
  cfg.use_apll = false;
  cfg.tx_desc_auto_clear = false;
  cfg.fixed_mclk = 0;
  cfg.mclk_multiple = I2S_MCLK_MULTIPLE_256;
  cfg.bits_per_chan = I2S_BITS_PER_CHAN_16BIT;
  i2s_pin_config_t pins = {};
  pins.bck_io_num = PIN_BCLK;
  pins.ws_io_num = PIN_LRCK;
  pins.data_out_num = I2S_PIN_NO_CHANGE;
  pins.data_in_num = PIN_DIN;
  pins.mck_io_num = PIN_MCLK;
  i2s_driver_install(I2S_NUM_1, &cfg, 0, NULL);
  i2s_set_pin(I2S_NUM_1, &pins);
  i2s_stop(I2S_NUM_1);

  jpeg.setPixelType(RGB565_BIG_ENDIAN);
  if (g_apMode) {
    showSetupScreen();
  } else {
    loadClip(kStates[g_state].file);
    showSplash(kStates[g_state].label);
  }
}

// ---------------- Loop ----------------
void loop() {
  if (g_recording) { recordLoop(); return; }

  if (g_apMode) {
    if (g_server) g_server->handleClient();
    if (pollButton() == 2) startRecording();
    delay(5);
    return;
  }

  if (g_frameCount == 0) { delay(200); return; }
  const uint32_t frameMs = 83;  // 12 fps
  for (int i = 0; i < g_frameCount; i++) {
    uint32_t t0 = millis();
    if (jpeg.openRAM(g_clip + g_frameOff[i], g_frameSize[i], jpegDraw)) {
      jpeg.decode(0, 0, 0);
      jpeg.close();
    }
    int act = pollButton();
    if (act == 1) {
      g_state = (g_state + 1) % kNumStates;
      loadClip(kStates[g_state].file);
      showSplash(kStates[g_state].label);
      return;
    } else if (act == 2) {
      startRecording();
      return;
    }
    uint32_t dt = millis() - t0;
    if (dt < frameMs) delay(frameMs - dt);
  }
}
