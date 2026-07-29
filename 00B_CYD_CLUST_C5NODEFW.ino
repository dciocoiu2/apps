#include <WiFi.h>
#include <WiFiClient.h>
#include <WiFiServer.h>
#include <esp_now.h>
#include <NimBLEDevice.h>

#define CTRL_SSID      "CLUSTER_CTRL"
#define CTRL_PASSWORD  "cluster123"
#define CTRL_PORT      3333

enum TransportMode { MODE_WIFI = 0, MODE_ESPNOW = 1 };
enum NodeRole      { ROLE_WIFI = 0, ROLE_BLE = 1, ROLE_BOTH = 2 };

TransportMode currentMode = MODE_WIFI;
NodeRole      currentRole = ROLE_BOTH;

WiFiServer ctrlServer(CTRL_PORT);
WiFiClient ctrlClient;

uint8_t hubEspNowPeer[6];
bool espNowReady = false;

const int channels[] = {1, 6, 11};
const int numChannels = sizeof(channels) / sizeof(channels[0]);
int currentChannelIndex = 0;
unsigned long lastChannelHop = 0;
const unsigned long channelHopInterval = 15000;

void setMode(TransportMode m) {
  currentMode = m;
  Serial.printf("Node [%s]: mode=%d\n", WiFi.macAddress().c_str(), (int)m);
}

void setRole(NodeRole r) {
  currentRole = r;
  Serial.printf("Node [%s]: role=%d\n", WiFi.macAddress().c_str(), (int)r);
}

void sendPacketWifi(const String &json) {
  if (ctrlClient.connected()) ctrlClient.println(json);
}

void sendPacketEspNow(const String &line) {
  if (espNowReady)
    esp_now_send(hubEspNowPeer, (const uint8_t*)line.c_str(), line.length());
}

void sendWardrive(const String &json, const String &line) {
  if (currentMode == MODE_WIFI) sendPacketWifi(json);
  else sendPacketEspNow(line);
}

void onEspNowSent(const uint8_t *mac_addr, esp_now_send_status_t status) {}

void setupEspNow() {
  if (esp_now_init() != ESP_OK) return;
  esp_now_register_send_cb(onEspNowSent);

  esp_now_peer_info_t peerInfo = {};
  memcpy(peerInfo.peer_addr, hubEspNowPeer, 6);
  peerInfo.channel = 0;
  peerInfo.encrypt = false;
  esp_now_add_peer(&peerInfo);
  espNowReady = true;
}

void handleControlClient() {
  if (!ctrlClient.connected()) return;

  while (ctrlClient.available()) {
    String line = ctrlClient.readStringUntil('\n');
    line.trim();
    if (!line.length()) continue;

    if (line.indexOf("\"cmd\":\"set_mode\"") >= 0) {
      int modeIndex = line.indexOf("\"mode\":");
      int val = line.substring(modeIndex + 7).toInt();
      if (val == 0 || val == 1) setMode((TransportMode)val);
    }

    if (line.indexOf("\"cmd\":\"set_role\"") >= 0) {
      int roleIndex = line.indexOf("\"role\":");
      int val = line.substring(roleIndex + 7).toInt();
      if (val >= 0 && val <= 2) setRole((NodeRole)val);
    }

    if (line.indexOf("\"cmd\":\"set_hub_mac\"") >= 0) {
      int macIndex = line.indexOf("\"mac\":\"");
      int start = macIndex + 7;
      int end = line.indexOf("\"", start);
      String macStr = line.substring(start, end);

      int last = 0;
      for (int i = 0; i < 6; i++) {
        int colon = macStr.indexOf(':', last);
        String part = (colon == -1 ? macStr.substring(last) : macStr.substring(last, colon));
        hubEspNowPeer[i] = strtol(part.c_str(), nullptr, 16);
        last = colon + 1;
      }
      setupEspNow();
    }
  }
}

void acceptControlClient() {
  if (!ctrlClient.connected()) {
    WiFiClient newClient = ctrlServer.available();
    if (newClient) {
      ctrlClient = newClient;
      Serial.println("Node: control client connected");
    }
  }
}

void hopChannelIfNeeded() {
  if (millis() - lastChannelHop > channelHopInterval) {
    lastChannelHop = millis();
    currentChannelIndex = (currentChannelIndex + 1) % numChannels;
    int ch = channels[currentChannelIndex];
    WiFi.setChannel(ch);
    Serial.printf("Node [%s]: hopped to channel %d\n",
                  WiFi.macAddress().c_str(), ch);
  }
}

void doWifiScan() {
  if (currentRole == ROLE_BLE) return;

  int n = WiFi.scanNetworks(false, true);
  Serial.printf("Node Wi-Fi: %d networks\n", n);

  for (int i = 0; i < n; i++) {
    String ssid = WiFi.SSID(i);
    String bssid = WiFi.BSSIDstr(i);
    int rssi = WiFi.RSSI(i);
    int channel = WiFi.channel(i);

    wifi_auth_mode_t auth = WiFi.encryptionType(i);
    String enc = (auth == WIFI_AUTH_OPEN ? "OPEN" : "SEC");

    String json = "{";
    json += "\"src\":\"node_wifi\",";
    json += "\"node_mac\":\"" + WiFi.macAddress() + "\",";
    json += "\"ap_mac\":\"" + bssid + "\",";
    json += "\"ssid\":\"" + ssid + "\",";
    json += "\"rssi\":" + String(rssi) + ",";
    json += "\"channel\":" + String(channel) + ",";
    json += "\"enc\":\"" + enc + "\"";
    json += "}";

    String line = "NODE_WIFI," + WiFi.macAddress() + "," + bssid + "," +
                  String(channel) + "," + String(rssi) + "," + ssid + "," + enc;

    sendWardrive(json, line);
  }
}

class BLEAdvertisedDeviceCallback : public NimBLEAdvertisedDeviceCallbacks {
  void onResult(NimBLEAdvertisedDevice* dev) override {
    if (currentRole == ROLE_WIFI) return;

    String mac = dev->getAddress().toString().c_str();
    int rssi = dev->getRSSI();
    std::string payload = dev->getPayload();

    String hexPayload = "";
    for (size_t i = 0; i < payload.size(); i++) {
      char buf[4];
      sprintf(buf, "%02X", (uint8_t)payload[i]);
      hexPayload += buf;
    }

    String json = "{";
    json += "\"src\":\"node_ble\",";
    json += "\"node_mac\":\"" + WiFi.macAddress() + "\",";
    json += "\"ble_mac\":\"" + mac + "\",";
    json += "\"rssi\":" + String(rssi) + ",";
    json += "\"payload\":\"" + hexPayload + "\"";
    json += "}";

    String line = "NODE_BLE," + WiFi.macAddress() + "," + mac + "," +
                  String(rssi) + "," + hexPayload;

    sendWardrive(json, line);
  }
};

void setupBle() {
  NimBLEDevice::init("C5Node");
  NimBLEDevice::setPower(ESP_PWR_LVL_P9);
  NimBLEScan* scan = NimBLEDevice::getScan();
  scan->setAdvertisedDeviceCallbacks(new BLEAdvertisedDeviceCallback());
  scan->setActiveScan(false);
  scan->setInterval(100);
  scan->setWindow(50);
  scan->setDuplicateFilter(true);
  scan->start(0, nullptr, false);
}

unsigned long lastWifiScan = 0;

void setup() {
  Serial.begin(115200);
  delay(500);

  WiFi.mode(WIFI_STA);
  WiFi.begin(CTRL_SSID, CTRL_PASSWORD);
  while (WiFi.status() != WL_CONNECTED) delay(250);

  ctrlServer.begin();
  setMode(MODE_WIFI);
  setRole(ROLE_BOTH);

  WiFi.setChannel(channels[currentChannelIndex]);
  setupBle();
}

void loop() {
  acceptControlClient();
  handleControlClient();
  hopChannelIfNeeded();

  if (millis() - lastWifiScan > 10000) {
    lastWifiScan = millis();
    doWifiScan();
  }
}