/*
  Modular Hardware CLI Controller for Arduino Giga R1 WiFi
  Target IDE: Arduino IDE 2.x
  Board: Arduino Giga R1 WiFi (STM32H747XI)
*/

#include <Wire.h>

// State tracking variables for hardware capabilities
bool i2cEnabled = false;

// Function prototypes for CLI command handlers
void handleHelp();
void handleStatus();
void handleI2C(String args);
void handlePinMode(String args);
void handleDigitalWrite(String args);
void handleDigitalRead(String args);
void processCommand(String cmd);

void setup() {
  // Initialize Serial communication for CLI at 115200 baud
  Serial.begin(115200);
  
  // Wait for native USB serial connection to establish
  uint32_t timeout = millis();
  while (!Serial && (millis() - timeout < 4000)) {
    delay(10);
  }

  Serial.println("\n==================================================");
  Serial.println(" Arduino Giga R1 WiFi - Modular CLI Hardware Daemon");
  Serial.println("==================================================");
  Serial.println("Type 'help' to view available modular commands.\n");
  Serial.print("GIGA-CLI> ");
}

void loop() {
  if (Serial.available() > 0) {
    String inputString = Serial.readStringUntil('\n');
    inputString.trim(); // Clean trailing spaces/carriage returns

    if (inputString.length() > 0) {
      Serial.println(inputString); // Echo command back
      processCommand(inputString);
      Serial.print("GIGA-CLI> ");
    }
  }
}

// Command dispatcher router
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
  } else if (verb == "i2c") {
    handleI2C(args);
  } else if (verb == "pinmode") {
    handlePinMode(args);
  } else if (verb == "write" || verb == "digitalwrite") {
    handleDigitalWrite(args);
  } else if (verb == "read" || verb == "digitalread") {
    handleDigitalRead(args);
  } else {
    Serial.println("Error: Unknown command. Type 'help' for a list of valid commands.");
  }
}

void handleHelp() {
  Serial.println("Available Modular CLI Commands:");
  Serial.println("  help                         - Display this help menu");
  Serial.println("  status                       - Show active hardware peripheral status");
  Serial.println("  i2c <on|off>                 - Turn on or off the primary I2C (Wire) bus");
  Serial.println("  pinmode <pin> <in|out|pullup>- Configure a specific digital pin's mode");
  Serial.println("  write <pin> <0|1>            - Drive a digital pin LOW (0) or HIGH (1)");
  Serial.println("  read <pin>                   - Read the digital state of a pin");
}

void handleStatus() {
  Serial.println("--- Hardware Capability Status ---");
  Serial.print("  I2C Peripheral (Wire):       ");
  Serial.println(i2cEnabled ? "ONLINE (Active)" : "OFFLINE (Disabled)");
  Serial.println("  System Architecture:         STM32H747XI (3.3V Logic)");
  Serial.println("----------------------------------");
}

void handleI2C(String args) {
  args.trim();
  args.toLowerCase();

  if (args == "on") {
    if (!i2cEnabled) {
      Wire.begin(); // Turns on the hardware I2C master capability
      i2cEnabled = true;
      Serial.println("-> Success: I2C peripheral turned ON and initialized.");
    } else {
      Serial.println("-> Notice: I2C peripheral is already active.");
    }
  } else if (args == "off") {
    if (i2cEnabled) {
      // Safely flag capability as offline
      i2cEnabled = false;
      Serial.println("-> Success: I2C peripheral turned OFF.");
    } else {
      Serial.println("-> Notice: I2C peripheral is already offline.");
    }
  } else {
    Serial.println("-> Error: Invalid option. Use 'i2c on' or 'i2c off'.");
  }
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
    Serial.print("-> Pin "); Serial.print(pin); Serial.println(" configured as INPUT.");
  } else if (modeStr == "out" || modeStr == "output") {
    pinMode(pin, OUTPUT);
    Serial.print("-> Pin "); Serial.print(pin); Serial.println(" configured as OUTPUT.");
  } else if (modeStr == "pullup" || modeStr == "input_pullup") {
    pinMode(pin, INPUT_PULLUP);
    Serial.print("-> Pin "); Serial.print(pin); Serial.println(" configured as INPUT_PULLUP.");
  } else {
    Serial.println("-> Error: Invalid mode. Use 'in', 'out', or 'pullup'.");
  }
}

void handleDigitalWrite(String args) {
  int spaceIdx = args.indexOf(' ');
  if (spaceIdx == -1) {
    Serial.println("-> Error Format. Usage: write <pin> <0|1>");
    return;
  }

  int pin = args.substring(0, spaceIdx).toInt();
  String valStr = args.substring(spaceIdx + 1);
  valStr.trim();

  int val = valStr.toInt();
  if (val == 0 || val == 1) {
    digitalWrite(pin, val == 1 ? HIGH : LOW);
    Serial.print("-> Pin "); Serial.print(pin); 
    Serial.println(val == 1 ? " driven HIGH (3.3V)." : " driven LOW (0V).");
  } else {
    Serial.println("-> Error: Value must be 0 (LOW) or 1 (HIGH).");
  }
}

void handleDigitalRead(String args) {
  args.trim();
  int pin = args.toInt();
  int val = digitalRead(pin);
  Serial.print("-> Pin "); Serial.print(pin); 
  Serial.print(" logical state read: ");
  Serial.println(val == HIGH ? "HIGH (1)" : "LOW (0)");
}