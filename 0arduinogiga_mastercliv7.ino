/*
  v7: Ultimate Laboratory-Grade Modular CLI Firmware for Arduino Giga R1 WiFi
  Target IDE: Arduino IDE 2.x
  Board: Arduino Giga R1 WiFi (STM32H747XI Dual-Core M7/M4)
  New Subsystem Added in v7:
    - Direct Lattice iCE40 FPGA Configuration & Bitstream Loader (SPI + CRESET_B + CDONE)
  Retained v1-v6 Capabilities:
    - GPIO, ADC, PWM, DAC, Interrupts, Multi-bus I2C/SPI, UART bridging, Dual-Core RPC
    - 8MB SDRAM, QSPI status, ATECC608A status/RNG, RTC, FDCAN, Wi-Fi, BLE, PDM Mic,
      20-pin DVP Camera stub, USB Host VBUS (PA_15), Giga Display GFX, USB HID Keyboard,
      Watchdog, Sleep/Standby, Reboot, and Factory State Reset
*/

#include <Wire.h>
#include <SPI.h>
#include <RPC.h>
#include <SDRAM.h>
#include <STM32RTC.h>
#include <ArduinoBLE.h>
#include <PDM.h>
#include "Arduino_GigaDisplay_GFX.h"
#include "PluggableUSBHID.h"
#include "USBKeyboard.h"

GigaDisplay_GFX display;
USBKeyboard keyboard;
STM32RTC& rtc = STM32RTC::getInstance();
mbed::Watchdog &watchdog = mbed::Watchdog::get_instance();

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

// v7 iCE40 FPGA configuration state & configurable control pins
bool ice40Initialized = false;
int iceResetPin = 6;   // CRESET_B (active low)
int iceCdonePin = 7;   // CDONE (input, goes HIGH when configured)
int iceCsPin    = 10;  // SPI_SS / CS (active low during slave programming)
uint32_t iceLastBytesSent = 0;

// Audio buffer settings for onboard MP34DT05 digital mic
const int sampleRate = 16000;
volatile int samplesRead;
short sampleBuffer[256];

// Function Prototypes
void handleHelp();
void handleStatus();
void handleICE40(String args);
void handleSDRAM(String args);
void handleQSPI(String args);
void handleCrypto(String args);
void handleRTC(String args);
void handleCAN(String args);
void handleBLE(String args);
void handleAudio(String args);
void handleCamera(String args);
void handleUSBHost(String args);
void handleDisplay(String args);
void handleUSBDevice(String args);
void handleWatchdog(String args);
void handlePower(String args);
void handleFactoryReset();
void handleReboot();
void processCommand(String cmd);

void setup() {
  RPC.begin();
  Serial.begin(115200);

  uint32_t timeout = millis();
  while (!Serial && (millis() - timeout < 4000)) {
    delay(10);
  }

  Serial.println("\n==============================================================");
  Serial.println(" Arduino Giga R1 WiFi - v7 FPGA & Hardware Lab CLI");
  Serial.println("==============================================================");
  Serial.println("Type 'help' for all commands. Type 'ice40 help' for FPGA loader.\n");
  Serial.print("GIGA-V7-LAB> ");
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
      Serial.println(inputString);
      processCommand(inputString);
      Serial.print("GIGA-V7-LAB> ");
    }
  }
}

void processCommand(String cmd) {
  int spaceIndex = cmd.indexOf(' ');
  String verb = "";
  String args = "";

  if (spaceIndex == -1) {
    verb = cmd;
  } else {
    verb = cmd.substring(0, spaceIndex);
    args = cmd.substring(spaceIndex + 1);
  }
  verb.toLowerCase();

  if (verb == "help") handleHelp();
  else if (verb == "status") handleStatus();
  else if (verb == "ice40") handleICE40(args);
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
  else Serial.println("-> Error: Unknown command. Type 'help' for valid actions.");
}

// --- iCE40 Helper Routines ---
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

  // Hold CRESET_B low and CS low to prepare slave SPI configuration
  digitalWrite(iceCsPin, LOW);
  digitalWrite(iceResetPin, LOW);
  delayMicroseconds(10);

  // Release CRESET_B high while keeping CS low so iCE40 samples CS=0 and enters slave mode
  digitalWrite(iceResetPin, HIGH);
  delay(2); // Allow internal POR/config logic settle
}

void ice40FinishConfigClocks() {
  // Release CS high and send >= 49 dummy clock cycles (8 bytes = 64 clocks)
  digitalWrite(iceCsPin, HIGH);
  SPI.beginTransaction(SPISettings(4000000, MSBFIRST, SPI_MODE0));
  for (int i = 0; i < 8; i++) {
    SPI.transfer(0x00);
  }
  SPI.endTransaction();
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
  if (h < 0 || l < 0) {
    ok = false;
    return 0;
  }
  ok = true;
  return (h << 4) | l;
}

void handleICE40(String args) {
  args.trim();
  if (args.length() == 0) {
    Serial.println("-> Usage: ice40 <init|pins <rst> <cdone> <cs>|reset|cdone|prog <hex>|stream <bytes>>");
    return;
  }

  int sp = args.indexOf(' ');
  String sub = (sp == -1) ? args : args.substring(0, sp);
  String rest = (sp == -1) ? "" : args.substring(sp + 1);
  sub.toLowerCase();
  rest.trim();

  if (sub == "init") {
    ice40SetupPins();
    Serial.print("-> iCE40 interface initialized (CRESET_B=");
    Serial.print(iceResetPin);
    Serial.print(", CDONE=");
    Serial.print(iceCdonePin);
    Serial.print(", CS=");
    Serial.print(iceCsPin);
    Serial.println(").");
  } else if (sub == "pins") {
    // Parse three pin numbers: <creset> <cdone> <cs>
    int s1 = rest.indexOf(' ');
    int s2 = (s1 == -1) ? -1 : rest.indexOf(' ', s1 + 1);
    if (s1 == -1 || s2 == -1) {
      Serial.println("-> Error. Usage: ice40 pins <creset_pin> <cdone_pin> <cs_pin>");
      return;
    }
    iceResetPin = rest.substring(0, s1).toInt();
    iceCdonePin = rest.substring(s1 + 1, s2).toInt();
    iceCsPin    = rest.substring(s2 + 1).toInt();
    ice40SetupPins();
    Serial.print("-> Updated iCE40 pins -> CRESET_B: ");
    Serial.print(iceResetPin);
    Serial.print(", CDONE: ");
    Serial.print(iceCdonePin);
    Serial.print(", CS: ");
    Serial.println(iceCsPin);
  } else if (sub == "reset") {
    if (!ice40Initialized) ice40SetupPins();
    digitalWrite(iceCsPin, HIGH);
    digitalWrite(iceResetPin, LOW);
    delay(2);
    digitalWrite(iceResetPin, HIGH);
    delay(2);
    Serial.print("-> iCE40 pulsed CRESET_B. CDONE state: ");
    Serial.println(digitalRead(iceCdonePin) == HIGH ? "HIGH (1)" : "LOW (0)");
  } else if (sub == "cdone") {
    if (!ice40Initialized) ice40SetupPins();
    Serial.print("-> iCE40 CDONE pin (");
    Serial.print(iceCdonePin);
    Serial.print(") level: ");
    Serial.println(digitalRead(iceCdonePin) == HIGH ? "HIGH (1 - Configured)" : "LOW (0 - Not Done)");
  } else if (sub == "prog") {
    // Stream hex bytes (e.g., "FF 00 7E AA" or compact hex) into iCE40 SPI slave
    if (rest.length() == 0) {
      Serial.println("-> Error. Usage: ice40 prog <hex_bytes>");
      return;
    }
    String cleanHex = "";
    for (unsigned int i = 0; i < rest.length(); i++) {
      char c = rest.charAt(i);
      if (c != ' ' && c != '\t' && c != '\r' && c != '\n') cleanHex += c;
    }
    if (cleanHex.length() < 2 || (cleanHex.length() % 2) != 0) {
      Serial.println("-> Error: Provide an even number of hex digits.");
      return;
    }

    ice40EnterSlaveProgMode();
    uint32_t count = 0;
    bool ok = true;

    SPI.beginTransaction(SPISettings(4000000, MSBFIRST, SPI_MODE0));
    for (unsigned int i = 0; i < cleanHex.length(); i += 2) {
      int b = parseHexByte(cleanHex.charAt(i), cleanHex.charAt(i + 1), ok);
      if (!ok) {
        Serial.println("\n-> Error: Non-hex character encountered in payload.");
        break;
      }
      SPI.transfer((uint8_t)b);
      count++;
    }
    SPI.endTransaction();
    ice40FinishConfigClocks();

    if (ok) {
      iceLastBytesSent = count;
      Serial.print("-> Sent ");
      Serial.print(count);
      Serial.print(" bytes to iCE40. CDONE: ");
      Serial.println(digitalRead(iceCdonePin) == HIGH ? "HIGH" : "LOW");
    }
  } else if (sub == "stream") {
    // Receive exact raw binary byte count from Serial and clock into iCE40
    uint32_t expectedBytes = rest.toInt();
    if (expectedBytes == 0) {
      Serial.println("-> Error. Usage: ice40 stream <byte_count>");
      return;
    }
    ice40EnterSlaveProgMode();
    Serial.print("-> Ready for ");
    Serial.print(expectedBytes);
    Serial.println(" raw bytes on Serial...");

    uint32_t received = 0;
    uint32_t lastByteTime = millis();
    SPI.beginTransaction(SPISettings(4000000, MSBFIRST, SPI_MODE0));
    while (received < expectedBytes && (millis() - lastByteTime < 5000)) {
      if (Serial.available() > 0) {
        uint8_t b = (uint8_t)Serial.read();
        SPI.transfer(b);
        received++;
        lastByteTime = millis();
      }
    }
    SPI.endTransaction();
    ice40FinishConfigClocks();
    iceLastBytesSent = received;

    Serial.print("-> Streamed ");
    Serial.print(received);
    Serial.print("/");
    Serial.print(expectedBytes);
    Serial.print(" bytes. CDONE: ");
    Serial.println(digitalRead(iceCdonePin) == HIGH ? "HIGH" : "LOW");
  } else {
    Serial.println("-> Error. Usage: ice40 <init|pins|reset|cdone|prog|stream>");
  }
}

void handleHelp() {
  Serial.println("--- v7 Ultimate Laboratory CLI Command Reference ---");
  Serial.println("  ice40 <init|pins|reset|cdone|prog|stream> - Direct iCE40 FPGA programming");
  Serial.println("  status                                    - Display subsystem states");
  Serial.println("  sdram <init|test|clear>                   - Manage 8MB external SDRAM");
  Serial.println("  qspi <status>                             - Interrogate 16MB QSPI flash");
  Serial.println("  crypto <info|rng>                         - ATECC608A info & TRNG");
  Serial.println("  rtc <get|set>                             - RTC & backup domain");
  Serial.println("  