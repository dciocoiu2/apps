/*
  Comprehensive Master Hardware CLI Firmware for Arduino Giga R1 WiFi
  Target IDE: Arduino IDE 2.x
  Board: Arduino Giga R1 WiFi (STM32H747XI Dual-Core)

*/

#include <Wire.h>
#include <SPI.h>
#include <WiFi.h>

// Subsystem state tracking variables
bool i2c0Enabled = false;
bool spi0Enabled = false;
bool wifiConnected = false;

// Function prototypes
void handleHelp();
void handleStatus();
void handlePinMode(String args);
void handleDigitalWrite(String args);
void handleDigitalRead(String args);
void handleAnalogRead(String args);
void handlePwmWrite(String args);
void handleI2C(String args);
void handleSPI(String args);
void handleWiFi(String args);
void processCommand(String cmd);

void setup() {
  Serial.begin(115200);
  
  uint32_t timeout = millis();
  while (!Serial && (millis() - timeout < 4000)) {
    delay(10);
  }

  Serial.println("\n==========================================================");
  Serial.println(" Arduino Giga R1 WiFi - Master Hardware Configuration CLI");
  Serial.println("==========================================================");
  Serial.println("Type 'help' to list all supported hardware subsystem commands.\n");
  Serial.print("GIGA-MASTER> ");
}

void loop() {
  if (Serial.available() > 0) {
    String inputString = Serial.readStringUntil('\n');
    inputString.trim();

    if (inputString.length() > 0) {
      Serial.println(inputString); // Echo command
      processCommand(inputString);
      Serial.print("GIGA-MASTER> ");
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

  if (verb == "help") {
    handleHelp();
  } else if (verb == "status") {
    handleStatus();
  } else if (verb == "pinmode") {
    handlePinMode(args);
  } else if (verb == "write" || verb == "digitalwrite") {
    handleDigitalWrite(args);
  } else if (verb == "read" || verb == "digitalread") {
    handleDigitalRead(args);
  } else if (verb == "analogread") {
    handleAnalogRead(args);
  } else if (verb == "pwm" || verb == "analogwrite") {
    handlePwmWrite(args);
  } else if (verb == "i2c") {
    handleI2C(args);
  } else if (verb == "spi") {
    handleSPI(args);
  } else if (verb == "wifi") {
    handleWiFi(args);
  } else {
    Serial.println("Error: Unknown command. Type 'help' for a valid command list.");
  }
}

void handleHelp() {
  Serial.println("Available Hardware Configuration Commands:");
  Serial.println("  help                             - Display this help menu");
  Serial.println("  status                           - Show state of all hardware subsystems");
  Serial.println("  pinmode <pin> <in|out|pullup>    - Configure digital pin direction");
  Serial.println("  write <pin> <0|1>                - Set digital pin LOW (0) or HIGH (1)");
  Serial.println("  read <pin>                       - Read digital pin state");
  Serial.println("  analogread <pin>                 - Read ADC value from analog pin (A0-A12)");
  Serial.println("  pwm <pin> <0-255>                - Output PWM signal on a PWM-capable pin");
  Serial.println("  i2c <on|off>                     - Turn on/off primary Wire (I2C) bus");
  Serial.println("  spi <on|off>                     - Turn on/off primary SPI bus");
  Serial.println("  wifi <ssid> <pass>               - Connect to a Wi-Fi network");
}

void handleStatus() {
  Serial.println("--- Giga R1 Hardware Subsystem Status ---");
  Serial.print("  I2C Bus (Wire):            "); Serial.println(i2c0Enabled ? "ONLINE" : "OFFLINE");
  Serial.print("  SPI Bus:                   "); Serial.println(spi0Enabled ? "ONLINE" : "OFFLINE");
  Serial.print("  Wi-Fi Link:                "); Serial.println(wifiConnected ? "CONNECTED" : "DISCONNECTED");
  Serial.println("  Core Architecture:         STM32H747XI (Dual Core M7/M4)");
  Serial.println("  Logic Voltage Level:       3.3V Strict");
  Serial.println("-----------------------------------------");
}

void handlePinMode(String args) {
  int spaceIdx = args.indexOf(' ');
  if (spaceIdx == -1) {
    Serial.println("-> Error Format. Usage: pinmode <pin> <in|out|pullup>");
    return;
  }
  int pin = args.substring(0, spaceIdx).toInt();
  String modeStr = args.substring(spaceIdx + 1);
  modeStr.trim();
  modeStr.toLowerCase();

  if (modeStr == "in" || modeStr == "input") {
    pinMode(pin, INPUT);
    Serial.print("-> Pin "); Serial.print(pin); Serial.println(" set to INPUT.");
  } else if (modeStr == "out" || modeStr == "output") {
    pinMode(pin, OUTPUT);
    Serial.print("-> Pin "); Serial.print(pin); Serial.println(" set to OUTPUT.");
  } else if (modeStr == "pullup") {
    pinMode(pin, INPUT_PULLUP);
    Serial.print("-> Pin "); Serial.print(pin); Serial.println(" set to INPUT_PULLUP.");
  } else {
    Serial.println("-> Error: Use 'in', 'out', or 'pullup'.");
  }
}

void handleDigitalWrite(String args) {
  int spaceIdx = args.indexOf(' ');
  if (spaceIdx == -1) {
    Serial.println("-> Error Format. Usage: write <pin> <0|1>");
    return;
  }
  int pin = args.substring(0, spaceIdx).toInt();
  int val = args.substring(spaceIdx + 1).toInt();
  
  if (val == 0 || val == 1) {
    digitalWrite(pin, val == 1 ? HIGH : LOW);
    Serial.print("-> Pin "); Serial.print(pin); 
    Serial.println(val == 1 ? " driven HIGH (3.3V)." : " driven LOW (0V).");
  } else {
    Serial.println("-> Error: Value must be 0 or 1.");
  }
}

void handleDigitalRead(String args) {
  args.trim();
  int pin = args.toInt();
  int val = digitalRead(pin);
  Serial.print("-> Pin "); Serial.print(pin); 
  Serial.print(" digital state: ");
  Serial.println(val == HIGH ? "HIGH (1)" : "LOW (0)");
}

void handleAnalogRead(String args) {
  args.trim();
  int pin = args.toInt();
  int val = analogRead(pin);
  Serial.print("-> Analog Pin "); Serial.print(pin); 
  Serial.print(" ADC Read (12-bit): ");
  Serial.println(val);
}

void handlePwmWrite(String args) {
  int spaceIdx = args.indexOf(' ');
  if (spaceIdx == -1) {
    Serial.println("-> Error Format. Usage: pwm <pin> <0-255>");
    return;
  }
  int pin = args.substring(0, spaceIdx).toInt();
  int dutyCycle = args.substring(spaceIdx + 1).toInt();
  
  analogWrite(pin, constrain(dutyCycle, 0, 255));
  Serial.print("-> PWM output set on pin "); Serial.print(pin); 
  Serial.print(" with duty cycle: "); Serial.println(dutyCycle);
}

void handleI2C(String args) {
  args.trim();
  args.toLowerCase();
  if (args == "on") {
    if (!i2c0Enabled) {
      Wire.begin();
      i2c0Enabled = true;
      Serial.println("-> Success: I2C (Wire) bus initialized and turned ON.");
    } else {
      Serial.println("-> Notice: I2C bus is already active.");
    }
  } else if (args == "off") {
    i2c0Enabled = false;
    Serial.println("-> Success: I2C bus tracking flagged offline.");
  } else {
    Serial.println("-> Error: Use 'i2c on' or 'i2c off'.");
  }
}

void handleSPI(String args) {
  args.trim();
  args.toLowerCase();
  if (args == "on") {
    if (!spi0Enabled) {
      SPI.begin();
      spi0Enabled = true;
      Serial.println("-> Success: SPI bus initialized and turned ON.");
    } else {
      Serial.println("-> Notice: SPI bus is already active.");
    }
  } else if (args == "off") {
    SPI.end();
    spi0Enabled = false;
    Serial.println("-> Success: SPI bus disabled.");
  } else {
    Serial.println("-> Error: Use 'spi on' or 'spi off'.");
  }
}

void handleWiFi(String args) {
  int spaceIdx = args.indexOf(' ');
  if (spaceIdx == -1) {
    Serial.println("-> Error Format. Usage: wifi <ssid> <password>");
    return;
  }
  String ssid = args.substring(0, spaceIdx);
  String pass = args.substring(spaceIdx + 1);
  ssid.trim();
  pass.trim();

  Serial.print("-> Connecting to Wi-Fi SSID: "); Serial.println(ssid);
  
  WiFi.begin(ssid.c0_str() ? ssid.c_str() : "", pass.c_str());
  
  uint32_t startAttempt = millis();
  while (WiFi.status() != WL_CONNECTED && (millis() - startAttempt < 10000)) {
    delay(500);
    Serial.print(".");
  }
  Serial.println();

  if (WiFi.status() == WL_CONNECTED) {
    wifiConnected = true;
    Serial.println("-> Success: Wi-Fi Connected!");
    Serial.print("-> IP Address assigned: ");
    Serial.println(WiFi.localIP());
  } else {
    wifiConnected = false;
    Serial.println("-> Error: Wi-Fi connection timed out or failed.");
  }
}