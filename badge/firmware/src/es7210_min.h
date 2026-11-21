#pragma once
#include <Arduino.h>
#include <Wire.h>

// Minimal ES7210 4-channel audio ADC driver (I2C control, slave mode).
// Register sequence adapted from Espressif's public esp-adf esp_codec_dev
// ES7210 driver (Apache-2.0). Configured for: slave mode, I2S standard
// format, 16-bit, MIC1+MIC2 enabled, 30 dB mic gain.
class ES7210 {
 public:
  static constexpr uint8_t I2C_ADDR = 0x40;

  bool begin(TwoWire &wire = Wire) {
    wire_ = &wire;
    // Reset
    if (!writeReg(0x00, 0xFF)) return false;  // RESET_REG00
    writeReg(0x00, 0x41);
    writeReg(0x01, 0x3F);  // CLOCK_OFF_REG01: all clocks off for config
    writeReg(0x09, 0x30);  // TIME_CONTROL0_REG09
    writeReg(0x0A, 0x30);  // TIME_CONTROL1_REG0A
    writeReg(0x23, 0x2A);  // ADC12_HPF2_REG23
    writeReg(0x22, 0x0A);  // ADC12_HPF1_REG22
    writeReg(0x20, 0x0A);  // ADC34_HPF2_REG20
    writeReg(0x21, 0x2A);  // ADC34_HPF1_REG21
    // Slave mode: MODE_CONFIG_REG08 bit0 = 0
    updateBits(0x08, 0x01, 0x00);
    writeReg(0x40, 0x43);  // ANALOG_REG40: VDDA 3.3V, VMID 5K start
    writeReg(0x41, 0x70);  // MIC12_BIAS_REG41: 2.87V
    writeReg(0x42, 0x70);  // MIC34_BIAS_REG42: 2.87V
    writeReg(0x07, 0x20);  // OSR_REG07
    writeReg(0x02, 0xC1);  // MAINCLK_REG02: use DLL, clear state
    micSelect();
    setBits16();
    // Save clock-off state (with enabled mic clocks cleared) for start()
    offReg_ = readReg(0x01);
    return true;
  }

  void start() {
    writeReg(0x01, offReg_);   // CLOCK_OFF_REG01
    writeReg(0x06, 0x00);      // POWER_DOWN_REG06
    writeReg(0x40, 0x43);      // ANALOG_REG40
    writeReg(0x47, 0x08);      // MIC1_POWER_REG47
    writeReg(0x48, 0x08);      // MIC2_POWER_REG48
    writeReg(0x49, 0x08);      // MIC3_POWER_REG49
    writeReg(0x4A, 0x08);      // MIC4_POWER_REG4A
    micSelect();
    writeReg(0x40, 0x43);      // ANALOG_REG40
    writeReg(0x00, 0x71);      // RESET_REG00: state machine run
    writeReg(0x00, 0x41);
  }

  void stop() {
    writeReg(0x47, 0xFF);
    writeReg(0x48, 0xFF);
    writeReg(0x49, 0xFF);
    writeReg(0x4A, 0xFF);
    writeReg(0x4B, 0xFF);      // MIC12_POWER_REG4B
    writeReg(0x4C, 0xFF);      // MIC34_POWER_REG4C
    writeReg(0x40, 0xC0);      // ANALOG_REG40
    writeReg(0x01, 0x7F);      // CLOCK_OFF_REG01
    writeReg(0x06, 0x07);      // POWER_DOWN_REG06
  }

 private:
  TwoWire *wire_ = nullptr;
  uint8_t offReg_ = 0x3F;
  static constexpr uint8_t GAIN_30DB = 0x0A;  // 3 dB steps, index 10

  bool writeReg(uint8_t reg, uint8_t val) {
    wire_->beginTransmission(I2C_ADDR);
    wire_->write(reg);
    wire_->write(val);
    return wire_->endTransmission() == 0;
  }
  uint8_t readReg(uint8_t reg) {
    wire_->beginTransmission(I2C_ADDR);
    wire_->write(reg);
    wire_->endTransmission(false);
    wire_->requestFrom(I2C_ADDR, (uint8_t)1);
    return wire_->available() ? wire_->read() : 0;
  }
  void updateBits(uint8_t reg, uint8_t mask, uint8_t data) {
    uint8_t v = readReg(reg);
    v = (v & ~mask) | (mask & data);
    writeReg(reg, v);
  }
  // Enable MIC1 + MIC2 (the board's dual-mic array), disable MIC3/4 path.
  void micSelect() {
    for (uint8_t r = 0x43; r <= 0x46; r++) updateBits(r, 0x10, 0x00);
    writeReg(0x4B, 0xFF);  // MIC12_POWER_REG4B off
    writeReg(0x4C, 0xFF);  // MIC34_POWER_REG4C off
    // MIC1
    updateBits(0x01, 0x0B, 0x00);
    writeReg(0x4B, 0x00);
    updateBits(0x43, 0x10, 0x10);            // MIC1_GAIN_REG43 enable
    updateBits(0x43, 0x0F, GAIN_30DB);
    // MIC2
    updateBits(0x01, 0x0B, 0x00);
    writeReg(0x4B, 0x00);
    updateBits(0x44, 0x10, 0x10);            // MIC2_GAIN_REG44 enable
    updateBits(0x44, 0x0F, GAIN_30DB);
    writeReg(0x12, 0x00);  // SDP_INTERFACE2_REG12: not TDM
  }
  void setBits16() {
    uint8_t v = readReg(0x11);               // SDP_INTERFACE1_REG11
    v = (v & 0x1F) | 0x60;                   // 16-bit
    v &= 0xFC;                               // I2S standard format
    // Note: the two masks above are applied in the reference driver as
    // separate read-modify-write passes; combined here on the same value.
    writeReg(0x11, v);
  }
};
