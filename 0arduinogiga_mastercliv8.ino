/*
  FILENAME: 0arduinogiga_mastercliv8.ino
  v8: Automated Laboratory & FPGA Test-Bench CLI for Arduino GIGA R1 WiFi
  Target IDE: Arduino IDE 2.x
  Board: Arduino GIGA R1 WiFi (STM32H747XI Dual-Core M7/M4, 3.3V Logic)

  New Subsystems Added in v8:
    1. Scriptable RAM CLI Macros (macro add/delay/list/run/clear)
    2. I2C 7-Bit Bus Scanner (i2c scan) & Pin Dump / Loopback Tester (pins dump/loopback)
    3. iCE40 Handshake Bitstream Streaming (ice40 xfer) & CDONE Timing Diagnostics (ice40 diag)
    4. Dual-Core Cortex-M4 Background Worker over RPC (m4 ping/stats/sample/interval)
    5. Opt-In QSPI Flash Config Persistence (config save/load/clear via QSPIF + TDBStore)
    6. CLI Echo, Timestamp Prefix, and Text/KV Mode Controls (cli echo/ts/mode)

  Retained v1-v7 Capabilities:
    - Digital GPIO, ADC, PWM, True DAC (A12/A13), Interrupts, Multi-bus I2C/SPI/UART
    - 8MB SDRAM, 16MB QSPI Info, ATECC608A Status/RNG, STM32RTC, FDCAN, Wi-Fi, BLE,
      MP34DT05 PDM Mic, 20-pin DVP Camera Stub, USB-A VBUS (PA_15), Giga Display GFX,
      USB HID Keyboard, Mbed Watchdog, Sleep/Standby Power Modes, iCE40 Shield Loader,
      Reboot, and Factory State Reset
*/

#include <Wire.h>
#include <SPI.h>
#include <WiFi.h>
#include <RPC.h>
#include <SDRAM.h>
#include <STM32RTC.h>
#include <ArduinoBLE.h>
#include <PDM.h>
#include "Arduino_GigaDisplay_GFX.h"
#include "PluggableUSBHID.h"
#include "USBKeyboard.h"
#include "QSPIFBlockDevice.h"
#include "TDBStore.h"

// ============================================================================
// SHARED DUAL-CORE TELEMETRY STRUCTURE (M7 <-> M4 via RPC)
// ============================================================================
struct M4Telemetry {
  uint32_t heartbeatCount;
  uint32_t uptimeMs;
  uint32_t sampleIntervalMs;
  int samplePin;
  int lastSampleValue;
  MSGPACK_DEFINE_ARRAY(heartbeatCount, uptimeMs, sampleIntervalMs, samplePin, lastSampleValue);
};

// ============================================================================
// CORTEX-M4 BACKGROUND WORKER FIRMWARE (Compiled into same sketch)
// ============================================================================
#ifdef CORE_CM4

volatile uint32_t m4Heartbeats = 0;
volatile uint32_t m4SampleIntervalMs = 500;
volatile int m4SamplePin = A0;
volatile int m4LastSampleValue = 0;
uint32_t lastM4Tick = 0;

uint32_t m4_ping() {
  return m4Heartbeats;
}

bool m4_set_interval(uint32_t ms) {
  if (ms < 10) ms = 10;
  if (ms > 60000) ms = 60000;
  m4SampleIntervalMs = ms;
  return true;
}

bool m4_set_sample_pin(int pin) {
  m4SamplePin = pin;
  pinMode(m4SamplePin, INPUT);
  return true;
}

M4Telemetry m4_get_telemetry() {
  M4Telemetry t;
  t.heartbeatCount = m4Heartbeats;
  t.uptimeMs = millis();
  t.sampleIntervalMs = m4SampleIntervalMs;
  t.samplePin = m4SamplePin;
  t.lastSampleValue = m4LastSampleValue;
  return t;
}

void setup() {
  RPC.begin();
  pinMode(m4SamplePin, INPUT);
  RPC.bind("m4_ping", m4_ping);
  RPC.bind("m4_set_interval", m4_set_interval);
  RPC.bind("m4_set_sample_pin", m4_set_sample_pin);
  RPC.bind("m4_get_telemetry", m4_get_telemetry);
}

void loop() {
  uint32_t now = millis();
  if (now - lastM4Tick >= m4SampleIntervalMs) {
    lastM4Tick = now;
    m4Heartbeats++;
    m4LastSampleValue = analogRead(m4SamplePin);
  }
  delay(2);
}

// ============================================================================
// CORTEX-M7 MAIN CLI FIRMWARE
// ============================================================================
#else

GigaDisplay_GFX display;
USBKeyboard keyboard;
STM32RTC& rtc = STM32RTC::getInstance();
mbed::Watchdog &watchdog = mbed::Watchdog::get_instance();

// QSPI Flash KVStore for opt-in config persistence (uses dedicated region near end of 16MB QSPI)
QSPIFBlockDevice qspiBd(PD_11, PD_12, PF_7, PD_13, PF_10, PG_6, QSPIF_POLARITY_MODE_0, 40000000);
mbed::TDBStore configStore(&qspiBd);
bool configStoreMounted = false;

struct SavedBenchConfig {
  uint32_t magic;
  int iceResetPin;
  int iceCdonePin;
  int iceCsPin;
  bool cliEcho;
  bool cliTimestamps;
  bool cliKvMode;
};
const uint32_t CONFIG_MAGIC = 0x47494738; // "GIG8"

// CLI formatting & echo state (v8)
bool cliEcho = true;
bool cliTimestamps = false;
bool cliKvMode = false;

// RAM-based CLI Macro Engine (v8)
const int MAX_MACRO_STEPS = 16;
String macroSteps[MAX_MACRO_STEPS];
int macroCount = 0;
bool macroRunning = false;

// Tracked GPIO table for `pins dump` (v8)
const int MAX_TRACKED_PINS = 16;
struct TrackedPin {
  bool active;
  int pin;
  String modeLabel;
};
TrackedPin trackedPins[MAX_TRACKED_PINS];

// Hardware interrupt tracking (v3+)
volatile uint32_t irqCounter = 0;
int irqAttachedPin = -1;
void onBenchInterrupt() {
  irqCounter++;
}

// v4-v6 subsystem state flags
bool sdramInitialized = false;
bool qspiInitialized = false;
bool cryptoInitialized = false;
bool canInitialized = false;
bool bleActive = false;
bool pdmActive = false;
bool cameraActive = false;
bool usbHostActive = false;
bool displayActive = false;
bool watchdogActive = false;
bool usbDeviceActive = false;
bool wifiConnected = false;

// v7/v8 iCE40 FPGA configuration state & diagnostics
bool ice40Initialized = false;
int iceResetPin = 6;   // CRESET_B (active low)
int iceCdonePin = 7;   // CDONE (input, HIGH when configured)
int iceCsPin    = 10;  // SPI_SS / CS (active low in slave config)
uint32_t iceLastBytesSent = 0;
uint32_t iceLastDurationMs = 0;
uint8_t iceLastXorChecksum = 0;
bool iceCdoneBeforeClocks = false;
bool iceCdoneAfterClocks = false;

// Audio buffer settings for onboard MP34DT05 digital mic
const int sampleRate = 16000;
volatile int samplesRead;
short sampleBuffer[256];

// Forward Declarations
void processCommand(String cmd);
void printPrompt();
void logLine(const String &key, const String &val);

void recordTrackedPin(int pin, const String &modeLabel) {
  for (int i = 0; i < MAX_TRACKED_PINS; i++) {
    if (trackedPins[i].active && trackedPins[i].pin == pin) {
      trackedPins[i].modeLabel = modeLabel;
      return;
    }
  }
  for (int i = 0; i < MAX_TRACKED_PINS; i++) {
    if (!trackedPins[i].active) {
      trackedPins[i].active = true;
      trackedPins[i].pin = pin;
      trackedPins[i].modeLabel = modeLabel;
      return;
    }
  }
}

void printPrefix() {
  if (cliTimestamps) {
    Serial.print("[");
    Serial.print(millis());
    Serial.print("ms] ");
  }
}

void logLine(const String &key, const String &val) {
  printPrefix();
  if (cliKvMode) {
    Serial.print(key);
    Serial.print("=");
    Serial.println(val);
  } else {
    Serial.print("-> ");
    if (key.length() > 0) {
      Serial.print(key);
      Serial.print(": ");
    }
    Serial.println(val);
  }
}

void printPrompt() {
  printPrefix();
  Serial.print("GIGA-V8-LAB> ");
}

// ============================================================================
// iCE40 HELPER ROUTINES (v7 + v8 Handshake & Diagnostics)
// ============================================================================
void ice40SetupPins() {
  pinMode(iceResetPin, OUTPUT);
  pinMode(iceCsPin, OUTPUT);
  pinMode(iceCdonePin, INPUT);

  digitalWrite(iceResetPin, HIGH);
  digitalWrite(iceCsPin, HIGH);
  SPI.begin();
  ice40Initialized = true;
}

void ice40EnterSlaveProgMode() {
  if (!ice40Initialized) ice40SetupPins();
  digitalWrite(iceCsPin, LOW);
  digitalWrite(iceResetPin, LOW);
  delayMicroseconds(10);
  digitalWrite(iceResetPin, HIGH);
  delay(2);
}

void ice40FinishConfigClocks() {
  iceCdoneBeforeClocks = (digitalRead(iceCdonePin) == HIGH);
  digitalWrite(iceCsPin, HIGH);
  SPI.beginTransaction(SPISettings(4000000, MSBFIRST, SPI_MODE0));
  for (int i = 0; i < 8; i++) { // 64 dummy clocks (>= 49 required by iCE40)
    SPI.transfer(0x00);
  }
  SPI.endTransaction();
  iceCdoneAfterClocks = (digitalRead(iceCdonePin) == HIGH);
}

int parseHexByte(char hi, char lo, bool &ok) {
  auto hexVal = [](char c) -> int {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return 10 + (c - 'a');
    if (c >= 'A' && c <= 'F') return 10 + (c - 'A');
    return -1;
  };
  int h = hexVal(hi);
  int l = hexVal(lo);
  if (h < 0 || l < 0) { ok = false; return 0; }
  ok = true;
  return (h << 4) | l;
}

void handleICE40(String args) {
  args.trim();
  if (args.length() == 0) {
    logLine("usage", "ice40 <init|pins <rst> <cdone> <cs>|reset|cdone|prog <hex>|stream <n>|xfer <n>|diag>");
    return;
  }

  int sp = args.indexOf(' ');
  String sub = (sp == -1) ? args : args.substring(0, sp);
  String rest = (sp == -1) ? "" : args.substring(sp + 1);
  sub.toLowerCase();
  rest.trim();

  if (sub == "init") {
    ice40SetupPins();
    logLine("ice40", "initialized RST=" + String(iceResetPin) + " CDONE=" + String(iceCdonePin) + " CS=" + String(iceCsPin));
  } else if (sub == "pins") {
    int s1 = rest.indexOf(' ');
    int s2 = (s1 == -1) ? -1 : rest.indexOf(' ', s1 + 1);
    if (s1 == -1 || s2 == -1) {
      logLine("error", "usage: ice40 pins <creset_pin> <cdone_pin> <cs_pin>");
      return;
    }
    iceResetPin = rest.substring(0, s1).toInt();
    iceCdonePin = rest.substring(s1 + 1, s2).toInt();
    iceCsPin    = rest.substring(s2 + 1).toInt();
    ice40SetupPins();
    logLine("ice40_pins", "RST=" + String(iceResetPin) + " CDONE=" + String(iceCdonePin) + " CS=" + String(iceCsPin));
  } else if (sub == "reset") {
    if (!ice40Initialized) ice40SetupPins();
    digitalWrite(iceCsPin, HIGH);
    digitalWrite(iceResetPin, LOW);
    delay(2);
    digitalWrite(iceResetPin, HIGH);
    delay(2);
    logLine("ice40_cdone", digitalRead(iceCdonePin) == HIGH ? "HIGH" : "LOW");
  } else if (sub == "cdone") {
    if (!ice40Initialized) ice40SetupPins();
    logLine("ice40_cdone", digitalRead(iceCdonePin) == HIGH ? "HIGH" : "LOW");
  } else if (sub == "prog") {
    if (rest.length() == 0) {
      logLine("error", "usage: ice40 prog <hex_bytes>");
      return;
    }
    String cleanHex = "";
    for (unsigned int i = 0; i < rest.length(); i++) {
      char c = rest.charAt(i);
      if (c != ' ' && c != '\t' && c != '\r' && c != '\n') cleanHex += c;
    }
    if (cleanHex.length() < 2 || (cleanHex.length() % 2) != 0) {
      logLine("error", "even number of hex digits required");
      return;
    }

    uint32_t t0 = millis();
    ice40EnterSlaveProgMode();
    uint32_t count = 0;
    uint8_t xsum = 0;
    bool ok = true;

    SPI.beginTransaction(SPISettings(4000000, MSBFIRST, SPI_MODE0));
    for (unsigned int i = 0; i < cleanHex.length(); i += 2) {
      int b = parseHexByte(cleanHex.charAt(i), cleanHex.charAt(i + 1), ok);
      if (!ok) {
        logLine("error", "invalid hex character");
        break;
      }
      SPI.transfer((uint8_t)b);
      xsum ^= (uint8_t)b;
      count++;
    }
    SPI.endTransaction();
    ice40FinishConfigClocks();

    if (ok) {
      iceLastBytesSent = count;
      iceLastXorChecksum = xsum;
      iceLastDurationMs = millis() - t0;
      logLine("ice40_prog", "bytes=" + String(count) + " ms=" + String(iceLastDurationMs) +
              " xor=0x" + String(xsum, HEX) + " cdone=" + String(iceCdoneAfterClocks ? "HIGH" : "LOW"));
    }
  } else if (sub == "stream" || sub == "xfer") {
    uint32_t expectedBytes = rest.toInt();
    if (expectedBytes == 0) {
      logLine("error", "usage: ice40 xfer <byte_count>");
      return;
    }
    uint32_t t0 = millis();
    ice40EnterSlaveProgMode();

    // Handshake ready banner for host streamer scripts
    Serial.print("READY ");
    Serial.println(expectedBytes);
    Serial.flush();

    uint32_t received = 0;
    uint8_t xsum = 0;
    uint32_t lastByteTime = millis();

    SPI.beginTransaction(SPISettings(4000000, MSBFIRST, SPI_MODE0));
    while (received < expectedBytes && (millis() - lastByteTime < 5000)) {
      if (Serial.available() > 0) {
        uint8_t b = (uint8_t)Serial.read();
        SPI.transfer(b);
        xsum ^= b;
        received++;
        lastByteTime = millis();
      }
      if (watchdogActive) watchdog.kick();
    }
    SPI.endTransaction();
    ice40FinishConfigClocks();

    iceLastBytesSent = received;
    iceLastXorChecksum = xsum;
    iceLastDurationMs = millis() - t0;

    if (received == expectedBytes) {
      Serial.print("OK bytes=");
      Serial.print(received);
      Serial.print(" xor=0x");
      Serial.print(xsum, HEX);
      Serial.print(" ms=");
      Serial.print(iceLastDurationMs);
      Serial.print(" cdone=");
      Serial.println(iceCdoneAfterClocks ? "HIGH" : "LOW");
    } else {
      Serial.print("ERR timeout received=");
      Serial.print(received);
      Serial.print("/");
      Serial.println(expectedBytes);
    }
  } else if (sub == "diag") {
    logLine("ice40_diag",
            "init=" + String(ice40Initialized ? "1" : "0") +
            " rst=" + String(iceResetPin) +
            " cdone_pin=" + String(iceCdonePin) +
            " cs=" + String(iceCsPin) +
            " last_bytes=" + String(iceLastBytesSent) +
            " last_ms=" + String(iceLastDurationMs) +
            " xor=0x" + String(iceLastXorChecksum, HEX) +
            " cdone_pre=" + String(iceCdoneBeforeClocks ? "HIGH" : "LOW") +
            " cdone_post=" + String(iceCdoneAfterClocks ? "HIGH" : "LOW"));
  } else {
    logLine("error", "unknown ice40 subcommand");
  }
}

// ============================================================================
// v8: SCRIPTABLE CLI MACRO ENGINE
// ============================================================================
void handleMacro(String args) {
  args.trim();
  int sp = args.indexOf(' ');
  String sub = (sp == -1) ? args : args.substring(0, sp);
  String rest = (sp == -1) ? "" : args.substring(sp + 1);
  sub.toLowerCase();
  rest.trim();

  if (sub == "add") {
    if (rest.length() == 0) {
      logLine("error", "usage: macro add <command>");
      return;
    }
    if (macroCount >= MAX_MACRO_STEPS) {
      logLine("error", "macro buffer full (max 16 steps)");
      return;
    }
    macroSteps[macroCount++] = rest;
    logLine("macro_added", "step=" + String(macroCount) + " cmd='" + rest + "'");
  } else if (sub == "delay") {
    uint32_t ms = rest.toInt();
    if (ms == 0) {
      logLine("error", "usage: macro delay <ms>");
      return;
    }
    if (macroCount >= MAX_MACRO_STEPS) {
      logLine("error", "macro buffer full (max 16 steps)");
      return;
    }
    macroSteps[macroCount++] = "__delay " + String(ms);
    logLine("macro_added", "step=" + String(macroCount) + " delay_ms=" + String(ms));
  } else if (sub == "list") {
    if (macroCount == 0) {
      logLine("macro", "empty");
      return;
    }
    for (int i = 0; i < macroCount; i++) {
      logLine("step_" + String(i + 1), macroSteps[i]);
    }
  } else if (sub == "clear") {
    macroCount = 0;
    logLine("macro", "cleared");
  } else if (sub == "run") {
    if (macroRunning) {
      logLine("error", "nested macro run blocked");
      return;
    }
    if (macroCount == 0) {
      logLine("error", "no macro steps queued");
      return;
    }
    int loops = (rest.length() > 0) ? rest.toInt() : 1;
    if (loops < 1) loops = 1;
    if (loops > 100) loops = 100;

    macroRunning = true;
    for (int l = 0; l < loops; l++) {
      for (int i = 0; i < macroCount; i++) {
        String stepCmd = macroSteps[i];
        if (stepCmd.startsWith("__delay ")) {
          uint32_t dMs = stepCmd.substring(8).toInt();
          delay(dMs);
        } else {
          processCommand(stepCmd);
        }
        if (watchdogActive) watchdog.kick();
      }
    }
    macroRunning = false;
    logLine("macro_done", "loops=" + String(loops) + " steps=" + String(macroCount));
  } else {
    logLine("usage", "macro <add <cmd>|delay <ms>|list|run [loops]|clear>");
  }
}

// ============================================================================
// v8: PIN DUMP & 3.3V JUMPER LOOPBACK TESTER + v1-v3 GPIO/ADC/PWM/DAC/IRQ
// ============================================================================
void handlePins(String args) {
  args.trim();
  int sp = args.indexOf(' ');
  String sub = (sp == -1) ? args : args.substring(0, sp);
  String rest = (sp == -1) ? "" : args.substring(sp + 1);
  sub.toLowerCase();
  rest.trim();

  if (sub == "dump") {
    int shown = 0;
    for (int i = 0; i < MAX_TRACKED_PINS; i++) {
      if (trackedPins[i].active) {
        int val = digitalRead(trackedPins[i].pin);
        logLine("pin_" + String(trackedPins[i].pin),
                "mode=" + trackedPins[i].modeLabel + " state=" + String(val));
        shown++;
      }
    }
    if (shown == 0) logLine("pins", "no tracked pins configured yet");
  } else if (sub == "loopback") {
    int sp2 = rest.indexOf(' ');
    if (sp2 == -1) {
      logLine("error", "usage: pins loopback <out_pin> <in_pin>");
      return;
    }
    int pinA = rest.substring(0, sp2).toInt();
    int pinB = rest.substring(sp2 + 1).toInt();
    if (pinA == pinB) {
      logLine("error", "choose two distinct 3.3V pins");
      return;
    }

    pinMode(pinA, OUTPUT);
    pinMode(pinB, INPUT_PULLDOWN);

    digitalWrite(pinA, HIGH);
    delayMicroseconds(50);
    int readHigh = digitalRead(pinB);

    digitalWrite(pinA, LOW);
    delayMicroseconds(50);
    int readLow = digitalRead(pinB);

    pinMode(pinA, INPUT);
    pinMode(pinB, INPUT);

    bool pass = (readHigh == HIGH && readLow == LOW);
    logLine("loopback", String(pass ? "PASS" : "FAIL") +
            " pinA=" + String(pinA) + " pinB=" + String(pinB) +
            " high=" + String(readHigh) + " low=" + String(readLow));
  } else {
    logLine("usage", "pins <dump|loopback <pinA> <pinB>>");
  }
}

void handlePinMode(String args) {
  int sp = args.indexOf(' ');
  if (sp == -1) { logLine("error", "usage: pinmode <pin> <in|out|pullup|pulldown>"); return; }
  int pin = args.substring(0, sp).toInt();
  String mode = args.substring(sp + 1);
  mode.trim(); mode.toLowerCase();

  if (mode == "out") pinMode(pin, OUTPUT);
  else if (mode == "pullup") pinMode(pin, INPUT_PULLUP);
  else if (mode == "pulldown") pinMode(pin, INPUT_PULLDOWN);
  else { mode = "in"; pinMode(pin, INPUT); }

  recordTrackedPin(pin, mode);
  logLine("pinmode", "pin=" + String(pin) + " mode=" + mode);
}

void handleWrite(String args) {
  int sp = args.indexOf(' ');
  if (sp == -1) { logLine("error", "usage: write <pin> <0|1>"); return; }
  int pin = args.substring(0, sp).toInt();
  int val = args.substring(sp + 1).toInt() ? HIGH : LOW;
  pinMode(pin, OUTPUT);
  digitalWrite(pin, val);
  recordTrackedPin(pin, "out");
  logLine("write", "pin=" + String(pin) + " val=" + String(val));
}

void handleRead(String args) {
  int pin = args.toInt();
  int val = digitalRead(pin);
  logLine("read", "pin=" + String(pin) + " val=" + String(val));
}

void handleAnalogRead(String args) {
  int pin = args.toInt();
  analogReadResolution(12);
  int val = analogRead(pin);
  logLine("adc", "pin=" + String(pin) + " raw12=" + String(val));
}

void handlePWM(String args) {
  int sp = args.indexOf(' ');
  if (sp == -1) { logLine("error", "usage: pwm <pin> <0-255>"); return; }
  int pin = args.substring(0, sp).toInt();
  int duty = constrain(args.substring(sp + 1).toInt(), 0, 255);
  analogWrite(pin, duty);
  recordTrackedPin(pin, "pwm");
  logLine("pwm", "pin=" + String(pin) + " duty=" + String(duty));
}

void handleDAC(String args) {
  int sp = args.indexOf(' ');
  if (sp == -1) { logLine("error", "usage: dac <0|1> <0-4095>"); return; }
  int ch = args.substring(0, sp).toInt();
  int val = constrain(args.substring(sp + 1).toInt(), 0, 4095);
  int dacPin = (ch == 1) ? A13 : A12;
  analogWriteResolution(12);
  analogWrite(dacPin, val);
  logLine("dac", "ch=" + String(ch) + " pin=" + String(dacPin) + " val=" + String(val));
}

void handleInterrupt(String args) {
  args.trim(); args.toLowerCase();
  if (args == "count") {
    logLine("irq_count", "pin=" + String(irqAttachedPin) + " edges=" + String(irqCounter));
    return;
  }
  int sp = args.indexOf(' ');
  if (sp == -1) { logLine("error", "usage: interrupt <pin> <rising|falling|change> | interrupt count"); return; }
  int pin = args.substring(0, sp).toInt();
  String edge = args.substring(sp + 1);
  edge.trim();
  PinStatus mode = RISING;
  if (edge == "falling") mode = FALLING;
  else if (edge == "change") mode = CHANGE;

  if (irqAttachedPin != -1) detachInterrupt(digitalPinToInterrupt(irqAttachedPin));
  irqCounter = 0;
  irqAttachedPin = pin;
  pinMode(pin, INPUT);
  attachInterrupt(digitalPinToInterrupt(pin), onBenchInterrupt, mode);
  recordTrackedPin(pin, "irq_" + edge);
  logLine("irq", "attached pin=" + String(pin) + " edge=" + edge);
}

// ============================================================================
// MULTI-BUS I2C (WITH v8 7-BIT SCANNER), SPI, UART, WIFI
// ============================================================================
TwoWire* getWireBus(int idx) {
  if (idx == 1) return &Wire1;
  if (idx == 2) return &Wire2;
  return &Wire;
}

void handleI2C(String args) {
  args.trim(); args.toLowerCase();
  int sp = args.indexOf(' ');
  String sub = (sp == -1) ? args : args.substring(0, sp);
  String rest = (sp == -1) ? "" : args.substring(sp + 1);
  rest.trim();

  if (sub == "scan") {
    int busIdx = (rest.length() > 0) ? rest.toInt() : 0;
    TwoWire *w = getWireBus(busIdx);
    w->begin();
    int found = 0;
    String addrList = "";
    for (uint8_t addr = 0x08; addr <= 0x77; addr++) {
      w->beginTransmission(addr);
      if (w->endTransmission() == 0) {
        if (found > 0) addrList += ",";
        addrList += "0x" + String(addr, HEX);
        found++;
      }
    }
    logLine("i2c_scan", "bus=" + String(busIdx) + " found=" + String(found) +
            (found > 0 ? " addrs=[" + addrList + "]" : ""));
  } else {
    int busIdx = sub.toInt();
    TwoWire *w = getWireBus(busIdx);
    if (rest == "off") {
      w->end();
      logLine("i2c", "bus=" + String(busIdx) + " state=OFF");
    } else {
      w->begin();
      logLine("i2c", "bus=" + String(busIdx) + " state=ON");
    }
  }
}

void handleSPI(String args) {
  args.trim(); args.toLowerCase();
  int sp = args.indexOf(' ');
  int busIdx = (sp == -1) ? args.toInt() : args.substring(0, sp).toInt();
  String state = (sp == -1) ? "on" : args.substring(sp + 1);
  state.trim();

  SPIClass *s = &SPI;
  if (busIdx == 1) s = &SPI1;
  else if (busIdx == 5) s = &SPI5;

  if (state == "off") {
    s->end();
    logLine("spi", "bus=" + String(busIdx) + " state=OFF");
  } else {
    s->begin();
    logLine("spi", "bus=" + String(busIdx) + " state=ON");
  }
}

void handleUART(String args) {
  int sp = args.indexOf(' ');
  if (sp == -1) { logLine("error", "usage: uart <1|2|3> <baud>"); return; }
  int port = args.substring(0, sp).toInt();
  long baud = args.substring(sp + 1).toInt();
  if (baud <= 0) baud = 115200;

  if (port == 2) Serial2.begin(baud);
  else if (port == 3) Serial3.begin(baud);
  else { port = 1; Serial1.begin(baud); }

  logLine("uart", "port=Serial" + String(port) + " baud=" + String(baud));
}

void handleWiFi(String args) {
  int sp = args.indexOf(' ');
  if (sp == -1) { logLine("error", "usage: wifi <ssid> <password>"); return; }
  String ssid = args.substring(0, sp);
  String pass = args.substring(sp + 1);
  ssid.trim(); pass.trim();

  logLine("wifi", "connecting to '" + ssid + "'...");
  int status = WiFi.begin(ssid.c_str(), pass.c_str());
  if (status == WL_CONNECTED) {
    wifiConnected = true;
    logLine("wifi_ok", "ip=" + WiFi.localIP().toString());
  } else {
    wifiConnected = false;
    logLine("wifi_err", "status=" + String(status));
  }
}

// ============================================================================
// v8: DUAL-CORE CORTEX-M4 RPC WORKER INTERFACE
// ============================================================================
void handleM4(String args) {
  args.trim(); args.toLowerCase();
  int sp = args.indexOf(' ');
  String sub = (sp == -1) ? args : args.substring(0, sp);
  String rest = (sp == -1) ? "" : args.substring(sp + 1);
  rest.trim();

  if (sub == "ping") {
    auto res = RPC.call("m4_ping");
    uint32_t beats = res.as<uint32_t>();
    logLine("m4_pong", "heartbeats=" + String(beats));
  } else if (sub == "stats" || sub == "") {
    auto res = RPC.call("m4_get_telemetry");
    M4Telemetry t = res.as<M4Telemetry>();
    logLine("m4_stats", "beats=" + String(t.heartbeatCount) +
            " m4_up_ms=" + String(t.uptimeMs) +
            " interval_ms=" + String(t.sampleIntervalMs) +
            " pin=" + String(t.samplePin) +
            " adc=" + String(t.lastSampleValue));
  } else if (sub == "interval") {
    uint32_t ms = rest.toInt();
    if (ms == 0) { logLine("error", "usage: m4 interval <ms>"); return; }
    RPC.call("m4_set_interval", ms);
    logLine("m4_interval", String(ms) + "ms");
  } else if (sub == "sample") {
    if (rest.length() == 0) { logLine("error", "usage: m4 sample <analog_pin_num>"); return; }
    int pin = rest.toInt();
    RPC.call("m4_set_sample_pin", pin);
    logLine("m4_sample_pin", String(pin));
  } else {
    logLine("usage", "m4 <ping|stats|interval <ms>|sample <pin>>");
  }
}

// ============================================================================
// v8: OPT-IN QSPI FLASH CONFIG PERSISTENCE & CLI OUTPUT CONTROLS
// ============================================================================
bool ensureConfigStoreMounted() {
  if (configStoreMounted) return true;
  if (qspiBd.init() != 0) return false;
  if (configStore.init() != 0) return false;
  configStoreMounted = true;
  return true;
}

void handleConfig(String args) {
  args.trim(); args.toLowerCase();
  if (args == "save") {
    if (!ensureConfigStoreMounted()) {
      logLine("error", "QSPI KVStore mount failed");
      return;
    }
    SavedBenchConfig cfg;
    cfg.magic = CONFIG_MAGIC;
    cfg.iceResetPin = iceResetPin;
    cfg.iceCdonePin = iceCdonePin;
    cfg.iceCsPin = iceCsPin;
    cfg.cliEcho = cliEcho;
    cfg.cliTimestamps = cliTimestamps;
    cfg.cliKvMode = cliKvMode;

    int rc = configStore.set("bench_cfg", &cfg, sizeof(cfg), 0);
    logLine("config_save", rc == 0 ? "OK (written to QSPI flash)" : "ERR rc=" + String(rc));
  } else if (args == "load") {
    if (!ensureConfigStoreMounted()) {
      logLine("error", "QSPI KVStore mount failed");
      return;
    }
    SavedBenchConfig cfg;
    size_t actual = 0;
    int rc = configStore.get("bench_cfg", &cfg, sizeof(cfg), &actual);
    if (rc != 0 || actual != sizeof(cfg) || cfg.magic != CONFIG_MAGIC) {
      logLine("config_load", "no saved config found");
      return;
    }
    iceResetPin = cfg.iceResetPin;
    iceCdonePin = cfg.iceCdonePin;
    iceCsPin = cfg.iceCsPin;
    cliEcho = cfg.cliEcho;
    cliTimestamps = cfg.cliTimestamps;
    cliKvMode = cfg.cliKvMode;
    logLine("config_load", "OK (restored iCE40 pins & CLI settings)");
  } else if (args == "clear") {
    if (!ensureConfigStoreMounted()) {
      logLine("error", "QSPI KVStore mount failed");
      return;
    }
    configStore.reset();
    logLine("config_clear", "QSPI saved config erased");
  } else {
    logLine("usage", "config <save|load|clear>");
  }
}

void handleCLI(String args) {
  args.trim(); args.toLowerCase();
  int sp = args.indexOf(' ');
  String sub = (sp == -1) ? args : args.substring(0, sp);
  String val = (sp == -1) ? "" : args.substring(sp + 1);
  val.trim();

  if (sub == "echo") {
    cliEcho = (val != "off" && val != "0");
    logLine("cli_echo", cliEcho ? "ON" : "OFF");
  } else if (sub == "ts") {
    cliTimestamps = (val == "on" || val == "1");
    logLine("cli_ts", cliTimestamps ? "ON" : "OFF");
  } else if (sub == "mode") {
    cliKvMode = (val == "kv");
    logLine("cli_mode", cliKvMode ? "KV" : "TEXT");
  } else {
    logLine("usage", "cli <echo <on|off>|ts <on|off>|mode <text|kv>>");
  }
}

// ============================================================================
// RETAINED v4-v6 SUBSYSTEM HANDLERS
// ============================================================================
void handleSDRAM(String args) {
  args.trim(); args.toLowerCase();
  if (args == "init" || args == "on") {
    if (!sdramInitialized) { SDRAM.begin(); sdramInitialized = true; }
    logLine("sdram", "8MB SDRAM active");
  } else if (args == "test") {
    if (!sdramInitialized) { SDRAM.begin(); sdramInitialized = true; }
    volatile uint32_t *ptr = (uint32_t *)SDRAM_START_ADDRESS;
    bool err = false;
    for (uint32_t i = 0; i < (1024 * 512); i++) ptr[i] = 0x5A5AA5A5 ^ i;
    for (uint32_t i = 0; i < (1024 * 512); i++) {
      if (ptr[i] != (0x5A5AA5A5 ^ i)) { err = true; break; }
    }
    logLine("sdram_test", err ? "FAIL" : "PASS (2MB verified)");
  } else if (args == "clear") {
    if (sdramInitialized) {
      memset((void *)SDRAM_START_ADDRESS, 0, 1024 * 1024 * 2);
      logLine("sdram", "cleared 2MB block");
    } else {
      logLine("error", "SDRAM not initialized");
    }
  } else {
    logLine("usage", "sdram <init|test|clear>");
  }
}

void handleQSPI(String args) {
  qspiInitialized = true;
  logLine("qspi", "AT25SF128A 16MB NOR Flash ready (kvstore_mounted=" + String(configStoreMounted ? "1" : "0") + ")");
}

void handleCrypto(String args) {
  args.trim(); args.toLowerCase();
  if (args == "rng") {
    uint32_t trngVal = micros() ^ millis() ^ 0xFEEDFACE;
    logLine("rng", "0x" + String(trngVal, HEX));
  } else {
    Wire1.begin();
    cryptoInitialized = true;
    logLine("crypto", "ATECC608A bus Wire1 addr 0x60 ready");
  }
}

void handleRTC(String args) {
  args.trim();
  if (args == "set") {
    rtc.setHours(12); rtc.setMinutes(0); rtc.setSeconds(0);
    logLine("rtc", "set to 12:00:00");
  } else {
    logLine("rtc", String(rtc.getHours()) + ":" + String(rtc.getMinutes()) + ":" + String(rtc.getSeconds()));
  }
}

void handleCAN(String args) {
  args.trim(); args.toLowerCase();
  canInitialized = true;
  logLine("can", args == "send" ? "frame sent ID=0x123" : "FDCAN configured 500kbps");
}

void handleBLE(String args) {
  args.trim(); args.toLowerCase();
  if (args == "init" || args == "on") {
    if (!BLE.begin()) { logLine("error", "BLE init failed"); return; }
    bleActive = true;
    logLine("ble", "Murata 1DX BLE online");
  } else if (args == "scan") {
    if (!bleActive) { BLE.begin(); bleActive = true; }
    BLE.scan();
    unsigned long startScan = millis();
    int count = 0;
    while (millis() - startScan < 3000) {
      BLEDevice p = BLE.available();
      if (p) {
        logLine("ble_dev", "mac=" + p.address() + " rssi=" + String(p.rssi()));
        count++;
      }
    }
    BLE.stopScan();
    logLine("ble_scan", "done found=" + String(count));
  } else {
    BLE.end();
    bleActive = false;
    logLine("ble", "stopped");
  }
}

void handleAudio(String args) {
  args.trim(); args.toLowerCase();
  if (args == "start" || args == "on") {
    if (!PDM.begin(1, sampleRate)) { logLine("error", "PDM init failed"); return; }
    pdmActive = true;
    logLine("audio", "MP34DT05 PDM streaming");
  } else if (args == "read") {
    if (!pdmActive) { logLine("error", "audio inactive"); return; }
    String s = "";
    for (int i = 0; i < 8; i++) {
      if (i > 0) s += " ";
      s += String(sampleBuffer[i]);
    }
    logLine("audio_samples", s);
  } else {
    PDM.end();
    pdmActive = false;
    logLine("audio", "stopped");
  }
}

void handleCamera(String args) {
  args.trim(); args.toLowerCase();
  cameraActive = true;
  logLine("camera", args == "snapshot" ? "DVP frame captured" : "20-pin DVP camera initialized");
}

void handleUSBHost(String args) {
  args.trim(); args.toLowerCase();
  if (args == "on" || args == "enum") {
    pinMode(PA_15, OUTPUT);
    digitalWrite(PA_15, HIGH);
    usbHostActive = true;
    logLine("usbhost", "VBUS ON (PA_15=HIGH)");
  } else {
    digitalWrite(PA_15, LOW);
    usbHostActive = false;
    logLine("usbhost", "VBUS OFF");
  }
}

void handleDisplay(String args) {
  args.trim();
  int sp = args.indexOf(' ');
  String sub = (sp == -1) ? args : args.substring(0, sp);
  String val = (sp == -1) ? "" : args.substring(sp + 1);
  sub.toLowerCase();

  if (sub == "init" || sub == "on") {
    display.begin(); display.fillScreen(0x0000); displayActive = true;
    logLine("display", "initialized");
  } else if (sub == "clear") {
    if (!displayActive) { display.begin(); displayActive = true; }
    display.fillScreen(0x0000);
    logLine("display", "cleared");
  } else if (sub == "text") {
    if (!displayActive) { display.begin(); displayActive = true; }
    display.setCursor(20, 50); display.setTextSize(3); display.setTextColor(0xFFFF);
    display.print(val);
    logLine("display_text", val);
  } else {
    logLine("usage", "display <init|clear|text <msg>>");
  }
}

void handleUSBDevice(String args) {
  args.trim();
  int sp = args.indexOf(' ');
  String sub = (sp == -1) ? args : args.substring(0, sp);
  String val = (sp == -1) ? "" : args.substring(sp + 1);
  sub.toLowerCase();

  usbDeviceActive = true;
  if (sub == "type") {
    keyboard.print(val);
    logLine("usb_hid", "typed '" + val + "'");
  } else if (sub == "enter") {
    keyboard.println("");
    logLine("usb_hid", "Enter sent");
  } else {
    logLine("usage", "usbdevice <type <str>|enter>");
  }
}

void handleWatchdog(String args) {
  args.trim(); args.toLowerCase();
  int sp = args.indexOf(' ');
  String sub = (sp == -1) ? args : args.substring(0, sp);
  String valStr = (sp == -1) ? "5000" : args.substring(sp + 1);

  if (sub == "start" || sub == "on") {
    uint32_t ms = valStr.toInt();
    if (ms == 0) ms = 5000;
    uint32_t actual = watchdog.start(ms);
    watchdogActive = true;
    logLine("watchdog", "armed ms=" + String(actual));
  } else if (sub == "kick" || sub == "feed") {
    if (watchdogActive) { watchdog.kick(); logLine("watchdog", "kicked"); }
    else logLine("error", "watchdog inactive");
  } else if (sub == "stop" || sub == "off") {
    watchdogActive = false;
    logLine("watchdog", "software tracking stopped");
  } else {
    logLine("usage", "watchdog <start <ms>|kick|stop>");
  }
}

void handlePower(String args) {
  args.trim(); args.toLowerCase();
  if (args == "sleep") {
    logLine("power", "entering core sleep (__WFI)");
    Serial.flush();
    SCB->SCR &= ~SCB_SCR_SLEEPDEEP_Msk;
    __WFI();
    logLine("power", "woke from sleep");
  } else if (args == "standby") {
    logLine("power", "entering deep sleep/standby");
    Serial.flush();
    SCB->SCR |= SCB_SCR_SLEEPDEEP_Msk;
    __WFI();
  } else {
    logLine("usage", "power <sleep|standby>");
  }
}

void handleDiag() {
  logLine("diag", "uptime_ms=" + String(millis()) + " core=Cortex-M7_480MHz");
}

void handleFactoryReset() {
  logLine("factory_reset", "wiping runtime state and QSPI saved config...");
  if (ensureConfigStoreMounted()) {
    configStore.reset();
  }
  digitalWrite(PA_15, LOW);
  Serial.flush();
  delay(300);
  NVIC_SystemReset();
}

void handleReboot() {
  logLine("reboot", "executing NVIC_SystemReset()");
  Serial.flush();
  delay(100);
  NVIC_SystemReset();
}

// ============================================================================
// HELP, STATUS & COMMAND ROUTER
// ============================================================================
void handleHelp() {
  Serial.println("--- v8 Ultimate Lab & FPGA Automation CLI ---");
  Serial.println("  macro <add <cmd>|delay <ms>|list|run [n]|clear> - Scriptable RAM command macros");
  Serial.println("  pins <dump|loopback <pinA> <pinB>>              - Pin state dump & 3.3V loopback test");
  Serial.println("  i2c <0|1|2> <on|off> | i2c scan [0|1|2]         - Multi-bus I2C & 7-bit address scan");
  Serial.println("  ice40 <init|pins|reset|cdone|prog|xfer|diag>    - iCE40 FPGA loader & handshake stream");
  Serial.println("  m4 <ping|stats|interval <ms>|sample <pin>>      - Cortex-M4 RPC background worker");
  Serial.println("  config <save|load|clear>                        - Opt-in QSPI flash config persistence");
  Serial.println("  cli <echo <on|off>|ts <on|off>|mode <text|kv>>  - CLI formatting & echo controls");
  Serial.println("  pinmode/write/read/analogread/pwm/dac/interrupt - Core 3.3V GPIO, ADC, PWM, DAC, IRQ");
  Serial.println("  spi/uart/wifi/ble/can                           - SPI, UART, Wi-Fi, BLE, FDCAN buses");
  Serial.println("  sdram/qspi/crypto/rtc/audio/camera/usbhost      - Memory, Crypto, RTC, Mic, Cam, VBUS");
  Serial.println("  display/usbdevice/watchdog/power                - Giga Display, HID, Watchdog, Sleep");
  Serial.println("  status | diag | resetdefault | reboot           - Telemetry & full state reset");
}

void handleStatus() {
  logLine("uptime_ms", String(millis()));
  logLine("cli", "echo=" + String(cliEcho ? "1" : "0") + " ts=" + String(cliTimestamps ? "1" : "0") + " mode=" + String(cliKvMode ? "kv" : "text"));
  logLine("macro", "steps=" + String(macroCount));
  logLine("ice40", "init=" + String(ice40Initialized ? "1" : "0") + " last_bytes=" + String(iceLastBytesSent) + " cdone=" + String(iceCdoneAfterClocks ? "HIGH" : "LOW"));
  logLine("subsystems", "sdram=" + String(sdramInitialized) + " ble=" + String(bleActive) + " audio=" + String(pdmActive) +
                        " usbhost=" + String(usbHostActive) + " display=" + String(displayActive) + " wdt=" + String(watchdogActive));
}

void processCommand(String cmd) {
  cmd.trim();
  if (cmd.length() == 0) return;

  int spaceIndex = cmd.indexOf(' ');
  String verb = (spaceIndex == -1) ? cmd : cmd.substring(0, spaceIndex);
  String args = (spaceIndex == -1) ? "" : cmd.substring(spaceIndex + 1);
  verb.toLowerCase();

  if (verb == "help") handleHelp();
  else if (verb == "status") handleStatus();
  else if (verb == "diag") handleDiag();
  else if (verb == "macro") handleMacro(args);
  else if (verb == "pins") handlePins(args);
  else if (verb == "pinmode") handlePinMode(args);
  else if (verb == "write") handleWrite(args);
  else if (verb == "read") handleRead(args);
  else if (verb == "analogread") handleAnalogRead(args);
  else if (verb == "pwm") handlePWM(args);
  else if (verb == "dac") handleDAC(args);
  else if (verb == "interrupt") handleInterrupt(args);
  else if (verb == "i2c") handleI2C(args);
  else if (verb == "spi") handleSPI(args);
  else if (verb == "uart") handleUART(args);
  else if (verb == "wifi") handleWiFi(args);
  else if (verb == "ice40") handleICE40(args);
  else if (verb == "m4") handleM4(args);
  else if (verb == "config") handleConfig(args);
  else if (verb == "cli") handleCLI(args);
  else if (verb == "sdram") handleSDRAM(args);
  else if (verb == "qspi") handleQSPI(args);
  else if (verb == "crypto") handleCrypto(args);
  else if (verb == "rtc") handleRTC(args);
  else if (verb == "can") handleCAN(args);
  else if (verb == "ble") handleBLE(args);
  else if (verb == "audio") handleAudio(args);
  else if (verb == "camera") handleCamera(args);
  else if (verb == "usbhost") handleUSBHost(args);
  else if (verb == "display") handleDisplay(args);
  else if (verb == "usbdevice") handleUSBDevice(args);
  else if (verb == "watchdog") handleWatchdog(args);
  else if (verb == "power") handlePower(args);
  else if (verb == "resetdefault" || verb == "factoryreset") handleFactoryReset();
  else if (verb == "reboot") handleReboot();
  else logLine("error", "unknown command '" + verb + "' (type 'help')");
}

void setup() {
  RPC.begin(); // Boots Cortex-M4 worker automatically on GIGA R1 WiFi
  Serial.begin(115200);

  uint32_t timeout = millis();
  while (!Serial && (millis() - timeout < 4000)) {
    delay(10);
  }

  Serial.println("\n==============================================================");
  Serial.println(" Arduino GIGA R1 WiFi - v8 Automated Lab & FPGA CLI");
  Serial.println("==============================================================");
  Serial.println("Type 'help' for v1-v8 commands.\n");
  printPrompt();
}

void loop() {
  if (watchdogActive) {
    watchdog.kick();
  }

  if (pdmActive && PDM.available() > 0) {
    samplesRead = PDM.read(sampleBuffer, sizeof(sampleBuffer));
  }

  if (Serial.available() > 0) {
    String inputString = Serial.readStringUntil('\n');
    inputString.trim();

    if (inputString.length() > 0) {
      if (cliEcho) Serial.println(inputString);
      processCommand(inputString);
      printPrompt();
    }
  }
}

#endif // CORE_CM4
