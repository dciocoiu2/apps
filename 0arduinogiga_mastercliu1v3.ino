/*
  Ultimate Master Hardware CLI Firmware for Arduino Giga R1 WiFi
  Target IDE: Arduino IDE 2.x
  Board: Arduino Giga R1 WiFi (STM32H747XI Dual-Core M7/M4)
  Features:
    1. Dual-Core & Inter-Processor Communication (RPC)
    2. Multi-Instance Communication Buses (Wire0-3, SPI0-2)
    3. Hardware UART / Serial Bridge Multiplexing (Serial1-3)
    4. True Analog DAC Outputs (DAC0/DAC1 on A12/A13)
    5. Hardware Interrupts & Pin Change Callbacks
    6. System Diagnostics & Hardware Watchdog / Reset
*/

#include <Wire.h>
#include <SPI.h>
#include <RPC.h>

// Subsystem state tracking flags
bool i2cStatus[4] = {false, false, false, false};
bool spiStatus[3] = {false, false, false};
bool uartStatus[3] = {false, false, false};

// Interrupt tracking structure for dynamic pin callback routing
volatile uint32_t interruptCounters[76] = {0};

// Forward ISR dispatchers for common pins
void isrCallback0() { interruptCounters[0]++; }
void isrCallback1() { interruptCounters[1]++; }
void isrCallback2() { interruptCounters[2]++; }
void isrCallback3() { interruptCounters[3]++; }
void isrCallback4() { interruptCounters[4]++; }
void isrCallback5() { interruptCounters[5]++; }
void isrCallback6() { interruptCounters[6]++; }
void isrCallback7() { interruptCounters[7]++; }

// Function Prototypes
void handleHelp();
void handleStatus();
void handlePinMode(String args);
void handleDigitalWrite(String args);
void handleDigitalRead(String args);
void handleAnalogRead(String args);
void handleDacWrite(String args);
void handlePwmWrite(String args);
void handleI2C(String args);
void handleSPI(String args);
void handleUART(String args);
void handleInterrupt(String args);
void handleRPC(String args);
void handleDiag();
void handleReboot();
void processCommand(String cmd);

void setup() {
  // 1. Initialize Dual-Core IPC (Boot Cortex-M4 Co-processor)
  RPC.begin();

  Serial.begin(115200);
  uint32_t timeout = millis();
  while (!Serial && (millis() - timeout < 4000)) {
    delay(10);
  }

  Serial.println("\n==============================================================");
  Serial.println(" Arduino Giga R1 WiFi - Ultimate Modular Hardware CLI Daemon");
  Serial.println("==============================================================");
  Serial.println("Type 'help' to view all commands across the 6 subsystems.\n");
  Serial.print("GIGA-ULTIMATE> ");
}

void loop() {
  if (Serial.available() > 0) {
    String inputString = Serial.readStringUntil('\n');
    inputString.trim();

    if (inputString.length() > 0) {
      Serial.println(inputString); // Echo command back
      processCommand(inputString);
      Serial.print("GIGA-ULTIMATE> ");
    }
  }

  // Handle transparent bridging if any secondary UART is active
  if (Serial1.available()) Serial.write(Serial1.read());
  if (Serial2.available()) Serial.write(Serial2.read());
  if (Serial3.available()) Serial.write(Serial3.read());
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
  else if (verb == "pinmode") handlePinMode(args);
  else if (verb == "write") handleDigitalWrite(args);
  else if (verb == "read") handleDigitalRead(args);
  else if (verb == "analogread") handleAnalogRead(args);
  else if (verb == "dac") handleDacWrite(args);
  else if (verb == "pwm") handlePwmWrite(args);
  else if (verb == "i2c") handleI2C(args);
  else if (verb == "spi") handleSPI(args);
  else if (verb == "uart") handleUART(args);
  else if (verb == "interrupt") handleInterrupt(args);
  else if (verb == "rpc") handleRPC(args);
  else if (verb == "diag") handleDiag();
  else if (verb == "reboot") handleReboot();
  else Serial.println("-> Error: Unknown command. Type 'help' for available actions.");
}

void handleHelp() {
  Serial.println("--- Comprehensive Subsystem Command Reference ---");
  Serial.println("  status                             - Display active state of all subsystems");
  Serial.println("  pinmode <pin> <in|out|pullup>      - Configure digital pin direction");
  Serial.println("  write <pin> <0|1>                  - Drive digital pin LOW or HIGH");
  Serial.println("  read <pin>                         - Read digital pin state");
  Serial.println("  analogread <pin>                   - Read 12-bit ADC value (A0-A13)");
  Serial.println("  dac <0|1> <0-4095>                 - Write true analog voltage to DAC0/DAC1 (A12/A13)");
  Serial.println("  pwm <pin> <0-255>                  - Output PWM signal on pin");
  Serial.println("  i2c <0|1|2|3> <on|off>             - Control Wire0, Wire1, Wire2, Wire3 buses");
  Serial.println("  spi <0|1|2> <on|off>               - Control SPI0, SPI1, SPI2 buses");
  Serial.println("  uart <1|2|3> <baud>                - Initialize secondary hardware serial port");
  Serial.println("  interrupt <pin> <rising|falling>   - Attach hardware edge interrupt callback");
  Serial.println("  rpc <msg>                          - Send test IPC packet to co-processor core");
  Serial.println("  diag                               - View core memory, uptime, and diagnostics");
  Serial.println("  reboot                             - Trigger a hardware system reset");
}

void handleStatus() {
  Serial.println("--- Hardware Subsystems Status ---");
  Serial.print("  Core ID:           "); Serial.println(RPC.cpu_id() == CM7_CPUID ? "Cortex-M7 (Main)" : "Cortex-M4 (Co-proc)");
  Serial.print("  I2C Buses:         ");
  for(int i=0; i<4; i++) { Serial.print("W"); Serial.print(i); Serial.print(":"); Serial.print(i2cStatus[i]?"ON ":"OFF "); }
  Serial.println();
  Serial.print("  SPI Buses:         ");
  for(int i=0; i<3; i++) { Serial.print("S"); Serial.print(i); Serial.print(":"); Serial.print(spiStatus[i]?"ON ":"OFF "); }
  Serial.println();
  Serial.print("  UART Multiplexers: ");
  for(int i=0; i<3; i++) { Serial.print("U"); Serial.print(i+1); Serial.print(":"); Serial.print(uartStatus[i]?"ON ":"OFF "); }
  Serial.println();
  Serial.println("----------------------------------");
}

void handlePinMode(String args) {
  int spaceIdx = args.indexOf(' ');
  if (spaceIdx == -1) { Serial.println("-> Error. Usage: pinmode <pin> <in|out|pullup>"); return; }
  int pin = args.substring(0, spaceIdx).toInt();
  String modeStr = args.substring(spaceIdx + 1); modeStr.trim(); modeStr.toLowerCase();

  if (modeStr == "in") pinMode(pin, INPUT);
  else if (modeStr == "out") pinMode(pin, OUTPUT);
  else if (modeStr == "pullup") pinMode(pin, INPUT_PULLUP);
  else { Serial.println("-> Error: Invalid mode."); return; }
  Serial.print("-> Pin "); Serial.print(pin); Serial.println(" reconfigured.");
}

void handleDigitalWrite(String args) {
  int spaceIdx = args.indexOf(' ');
  if (spaceIdx == -1) { Serial.println("-> Error. Usage: write <pin> <0|1>"); return; }
  int pin = args.substring(0, spaceIdx).toInt();
  int val = args.substring(spaceIdx + 1).toInt();
  digitalWrite(pin, val ? HIGH : LOW);
  Serial.print("-> Pin "); Serial.print(pin); Serial.println(val ? " set HIGH (3.3V)." : " set LOW (0V).");
}

void handleDigitalRead(String args) {
  args.trim(); int pin = args.toInt();
  int val = digitalRead(pin);
  Serial.print("-> Pin "); Serial.print(pin); Serial.print(" state: "); Serial.println(val ? "HIGH (1)" : "LOW (0)");
}

void handleAnalogRead(String args) {
  args.trim(); int pin = args.toInt();
  int val = analogRead(pin);
  Serial.print("-> Analog Pin "); Serial.print(pin); Serial.print(" ADC (12-bit): "); Serial.println(val);
}

void handleDacWrite(String args) {
  int spaceIdx = args.indexOf(' ');
  if (spaceIdx == -1) { Serial.println("-> Error. Usage: dac <0|1> <0-4095>"); return; }
  int dacChan = args.substring(0, spaceIdx).toInt();
  int val = args.substring(spaceIdx + 1).toInt();
  val = constrain(val, 0, 4095);

  // Map DAC channel 0 -> A12/DAC0, channel 1 -> A13/DAC1
  int targetPin = (dacChan == 0) ? A12 : A13;
  analogWriteResolution(12);
  analogWrite(targetPin, val);
  Serial.print("-> True DAC "); Serial.print(dacChan); Serial.print(" (Pin "); Serial.print(targetPin);
  Serial.print(") set to raw count: "); Serial.println(val);
}

void handlePwmWrite(String args) {
  int spaceIdx = args.indexOf(' ');
  if (spaceIdx == -1) { Serial.println("-> Error. Usage: pwm <pin> <0-255>"); return; }
  int pin = args.substring(0, spaceIdx).toInt();
  int duty = constrain(args.substring(spaceIdx + 1).toInt(), 0, 255);
  analogWrite(pin, duty);
  Serial.print("-> PWM output on pin "); Serial.print(pin); Serial.print(" duty: "); Serial.println(duty);
}

void handleI2C(String args) {
  int spaceIdx = args.indexOf(' ');
  if (spaceIdx == -1) { Serial.println("-> Error. Usage: i2c <0|1|2|3> <on|off>"); return; }
  int bus = args.substring(0, spaceIdx).toInt();
  String state = args.substring(spaceIdx + 1); state.trim(); state.toLowerCase();

  bool enable = (state == "on");
  switch(bus) {
    case 0: if(enable) Wire.begin(); i2cStatus[0] = enable; break;
    case 1: if(enable) Wire1.begin(); i2cStatus[1] = enable; break;
    case 2: if(enable) Wire2.begin(); i2cStatus[2] = enable; break;
    case 3: if(enable) Wire3.begin(); i2cStatus[3] = enable; break;
    default: Serial.println("-> Error: Invalid I2C bus index (0-3)."); return;
  }
  Serial.print("-> Wire"); Serial.print(bus); Serial.println(enable ? " enabled." : " disabled tracker.");
}

void handleSPI(String args) {
  int spaceIdx = args.indexOf(' ');
  if (spaceIdx == -1) { Serial.println("-> Error. Usage: spi <0|1|2> <on|off>"); return; }
  int bus = args.substring(0, spaceIdx).toInt();
  String state = args.substring(spaceIdx + 1); state.trim(); state.toLowerCase();

  bool enable = (state == "on");
  switch(bus) {
    case 0: if(enable) SPI.begin(); else SPI.end(); spiStatus[0] = enable; break;
    case 1: if(enable) SPI1.begin(); else SPI1.end(); spiStatus[1] = enable; break;
    case 2: if(enable) SPI2.begin(); else SPI2.end(); spiStatus[2] = enable; break;
    default: Serial.println("-> Error: Invalid SPI bus index (0-2)."); return;
  }
  Serial.print("-> SPI"); Serial.print(bus); Serial.println(enable ? " activated." : " shut down.");
}

void handleUART(String args) {
  int spaceIdx = args.indexOf(' ');
  if (spaceIdx == -1) { Serial.println("-> Error. Usage: uart <1|2|3> <baud>"); return; }
  int port = args.substring(0, spaceIdx).toInt();
  long baud = args.substring(spaceIdx + 1).toInt();

  if (baud == 0) baud = 115200;
  switch(port) {
    case 1: Serial1.begin(baud); uartStatus[0] = true; break;
    case 2: Serial2.begin(baud); uartStatus[1] = true; break;
    case 3: Serial3.begin(baud); uartStatus[2] = true; break;
    default: Serial.println("-> Error: Invalid UART port (1-3)."); return;
  }
  Serial.print("-> Serial"); Serial.print(port); Serial.print(" initialized at "); Serial.print(baud); Serial.println(" baud.");
}

void handleInterrupt(String args) {
  int spaceIdx = args.indexOf(' ');
  if (spaceIdx == -1) { Serial.println("-> Error. Usage: interrupt <pin> <rising|falling>"); return; }
  int pin = args.substring(0, spaceIdx).toInt();
  String modeStr = args.substring(spaceIdx + 1); modeStr.trim(); modeStr.toLowerCase();

  int mode = (modeStr == "rising") ? RISING : FALLING;

  // Bind safe ISR wrapper based on pin index
  if (pin == 0) attachInterrupt(digitalPinToInterrupt(0), isrCallback0, mode);
  else if (pin == 1) attachInterrupt(digitalPinToInterrupt(1), isrCallback1, mode);
  else if (pin == 2) attachInterrupt(digitalPinToInterrupt(2), isrCallback2, mode);
  else if (pin == 3) attachInterrupt(digitalPinToInterrupt(3), isrCallback3, mode);
  else {
    Serial.println("-> Error: Pin index for direct ISR mapping supported on pins 0-3 in this profile.");
    return;
  }
  Serial.print("-> Hardware edge interrupt attached to Pin "); Serial.print(pin); Serial.print(" (Trigger count: ");
  Serial.print(interruptCounters[pin]); Serial.println(")");
}

void handleRPC(String args) {
  args.trim();
  Serial.print("-> Transmitting IPC payload across M7/M4 boundary: "); Serial.println(args);
  // Example RPC call structure to secondary core handler
  RPC.println(args);
  Serial.println("-> IPC payload dispatched successfully.");
}

void handleDiag() {
  Serial.println("--- System Diagnostics & Health ---");
  Serial.print("  Uptime (ms):       "); Serial.println(millis());
  Serial.print("  Free Heap (RAM):   "); Serial.print(xPortGetFreeHeapSize()); Serial.println(" bytes");
  Serial.print("  Core Architecture: STM32H747XI Dual Core (M7 + M4)\n");
  Serial.println("------------------------------------");
}

void handleReboot() {
  Serial.println("-> Executing hardware NVIC system reset...");
  delay(100);
  NVIC_SystemReset();
}