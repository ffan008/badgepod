#pragma once
#include <Arduino.h>
#include <Wire.h>

// Minimal CST9217 capacitive touch driver (I2C 0x5A, 16-bit register
// addresses, big-endian). Written from the chip's register facts:
//   0xD000  touch data block (read 15 bytes for up to 2 points)
//   0xD109  enter normal mode
// Touch block layout: byte0 = point0 (id<<4 | event, event 0x06 =
// contact), byte1/2 = X/Y high bits, byte3 = X/Y low nibbles,
// byte4 = status flags, byte5 = point count (bits 0-6), byte6 = 0xAB
// marker. After each read the host must ACK by writing 0xAB to 0xD000.
// Coordinates are 12-bit values pre-scaled by the controller firmware
// to the panel resolution (466x466 on this board).
class CST9217 {
 public:
  static constexpr uint8_t I2C_ADDR = 0x5A;

  // rstPin/intPin follow the board wiring (TP_RST=2, TP_INT=11).
  bool begin(TwoWire &wire = Wire, int rstPin = 2, int intPin = 11) {
    wire_ = &wire;
    pinMode(intPin, INPUT);
    pinMode(rstPin, OUTPUT);
    digitalWrite(rstPin, LOW);
    delay(10);
    digitalWrite(rstPin, HIGH);
    delay(50);
    // Enter normal mode: writing the register address alone is the
    // mode-switch command for this register family.
    if (!writeRegAddr(0xD109)) return false;
    delay(10);
    return true;
  }

  // Returns true while a finger is in contact; x/y in panel pixels.
  bool poll(int &x, int &y) {
    uint8_t buf[15] = {0};
    if (!readBlock(0xD000, buf, sizeof(buf))) return false;
    ack();
    if (buf[0] == 0xAB || buf[6] != 0xAB || buf[0] == 0x00) return false;
    int count = buf[5] & 0x7F;
    if (count < 1 || count > 2) return false;
    if ((buf[0] & 0x0F) != 0x06) return false;  // 0x06 = contact
    x = ((int)buf[1] << 4) | (buf[3] >> 4);
    y = ((int)buf[2] << 4) | (buf[3] & 0x0F);
    return true;
  }

 private:
  TwoWire *wire_ = nullptr;

  bool writeRegAddr(uint16_t reg) {
    wire_->beginTransmission(I2C_ADDR);
    wire_->write((uint8_t)(reg >> 8));
    wire_->write((uint8_t)(reg & 0xFF));
    return wire_->endTransmission() == 0;
  }
  bool readBlock(uint16_t reg, uint8_t *buf, size_t len) {
    if (!writeRegAddr(reg)) return false;
    size_t got = wire_->requestFrom(I2C_ADDR, (uint8_t)len);
    if (got != len) return false;
    for (size_t i = 0; i < len; i++) buf[i] = wire_->read();
    return true;
  }
  void ack() {
    wire_->beginTransmission(I2C_ADDR);
    wire_->write(0xD0);
    wire_->write(0x00);
    wire_->write(0xAB);
    wire_->endTransmission();
  }
};
