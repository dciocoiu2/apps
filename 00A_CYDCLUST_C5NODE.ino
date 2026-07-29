// CYD Hub Firmware: AP + receiver + SD PCAP + Biscuit-style LVGL dashboard, NO scanning
#include <WiFi.h>
#include <WiFiClient.h>
#include <WiFiServer.h>
#include <esp_now.h>
#include <SD.h>
#include <SPI.h>
#include <vector>

#include <lvgl.h>
#include <Arduino_GFX_Library.h>

#define CTRL_SSID      "CLUSTER_CTRL"
#define CTRL_PASSWORD  "cluster123"
#define CTRL_PORT      3333
#define SD_CS_PIN      5

// ---- Display config (adjust pins for your CYD) ----
Arduino_DataBus *bus = new Arduino_ESP32SPI(27 /* DC */, 5 /* CS */, 18 /* SCK */, 23 /* MOSI */, -1 /* MISO */);
Arduino_GFX *gfx = new Arduino_ILI9341(bus, 33 /* RST */, 0 /* rotation */, false /* IPS */);

static const uint16_t SCREEN_WIDTH  = 240;
static const uint16_t SCREEN_HEIGHT = 320;
static lv_disp_draw_buf_t draw_buf;
static lv_color_t buf1[SCREEN_WIDTH * 40];

// ---- Node model ----
struct NodeInfo {
  IPAddress ip;
  String mac;
  WiFiClient ctrlClient;
  int mode; // 0=WiFi,1=ESPNOW
  unsigned long lastSeen;
};

std::vector<NodeInfo> nodes;

WiFiServer ctrlServer(CTRL_PORT);
File pcapFile;

// ---- PCAP ----
const uint8_t PCAP_GLOBAL_HEADER[24] = {
  0xd4, 0xc3, 0xb2, 0xa1,
  0x02, 0x00, 0x04, 0x00,
  0x00, 0x00, 0x00, 0x00,
  0x00, 0x00, 0x00, 0x00,
  0xff, 0xff, 0x00, 0x00,
  0x7f, 0x00, 0x00, 0x00
};

void writePcapPacket(File &f, const uint8_t *payload, uint32_t len) {
  uint32_t ts_sec = millis() / 1000;
  uint32_t ts_usec = (millis() % 1000) * 1000;

  uint8_t hdr[16];
  memcpy(hdr, &ts_sec, 4);
  memcpy(hdr + 4, &ts_usec, 4);
  memcpy(hdr + 8, &len, 4);
  memcpy(hdr + 12, &len, 4);

  f.write(hdr, 16);
  f.write(payload, len);
}

// ---- LVGL objects ----
lv_obj_t *label_status;
lv_obj_t *table_nodes;
lv_obj_t *table_wifi;
lv_obj_t *table_ble;
lv_obj_t *btn_start;
lv_obj_t *btn_stop;

bool captureEnabled = true;

// ---- LVGL display flush ----
void lvgl_flush_cb(lv_disp_drv_t *disp, const lv_area_t *area, lv_color_t *color_p) {
  int32_t w = area->x2 - area->x1 + 1;
  int32_t h = area->y2 - area->y1 + 1;

  gfx->startWrite();
  gfx->setAddrWindow(area->x1, area->y1, w, h);
  gfx->writePixels((uint16_t *)&color_p->full, w * h);
  gfx->endWrite();

  lv_disp_flush_ready(disp);
}

// ---- LVGL UI setup (Biscuit-style dashboard) ----
void setup_ui() {
  lv_obj_t *scr = lv_scr_act();

  // Status bar
  label_status = lv_label_create(scr);
  lv_obj_align(label_status, LV_ALIGN_TOP_LEFT, 4, 4);
  lv_label_set_text(label_status, "CYD Hub: capture ON");

  // Nodes table
  table_nodes = lv_table_create(scr);
  lv_obj_set_size(table_nodes, SCREEN_WIDTH - 8, 80);
  lv_obj_align(table_nodes, LV_ALIGN_TOP_LEFT, 4, 24);
  lv_table_set_col_cnt(table_nodes, 4);
  lv_table_set_row_cnt(table_nodes, 4);
  lv_table_set_cell_value(table_nodes, 0, 0, "MAC");
  lv_table_set_cell_value(table_nodes, 0, 1, "IP");
  lv_table_set_cell_value(table_nodes, 0, 2, "Mode");
  lv_table_set_cell_value(table_nodes, 0, 3, "Last");

  // Wi-Fi AP table
  table_wifi = lv_table_create(scr);
  lv_obj_set_size(table_wifi, SCREEN_WIDTH - 8, 100);
  lv_obj_align(table_wifi, LV_ALIGN_LEFT_MID, 4, 0);
  lv_table_set_col_cnt(table_wifi, 4);
  lv_table_set_row_cnt(table_wifi, 6);
  lv_table_set_cell_value(table_wifi, 0, 0, "SSID");
  lv_table_set_cell_value(table_wifi, 0, 1, "BSSID");
  lv_table_set_cell_value(table_wifi, 0, 2, "RSSI");
  lv_table_set_cell_value(table_wifi, 0, 3, "Ch");

  // BLE table
  table_ble = lv_table_create(scr);
  lv_obj_set_size(table_ble, SCREEN_WIDTH - 8, 80);
  lv_obj_align(table_ble, LV_ALIGN_BOTTOM_LEFT, 4, -40);
  lv_table_set_col_cnt(table_ble, 3);
  lv_table_set_row_cnt(table_ble, 5);
  lv_table_set_cell_value(table_ble, 0, 0, "MAC");
  lv_table_set_cell_value(table_ble, 0, 1, "RSSI");
  lv_table_set_cell_value(table_ble, 0, 2, "Payload");

  // Buttons
  btn_start = lv_btn_create(scr);
  lv_obj_set_size(btn_start, 60, 24);
  lv_obj_align(btn_start, LV_ALIGN_BOTTOM_LEFT, 4, -8);
  lv_obj_t *lbl_s = lv_label_create(btn_start);
  lv_label_set_text(lbl_s, "Start");

  btn_stop = lv_btn_create(scr);
  lv_obj_set_size(btn_stop, 60, 24);
  lv_obj_align(btn_stop, LV_ALIGN_BOTTOM_RIGHT, -4, -8);
  lv_obj_t *lbl_t = lv_label_create(btn_stop);
  lv_label_set_text(lbl_t, "Stop");

  lv_obj_add_event_cb(btn_start, [](lv_event_t *e) {
    captureEnabled = true;
    lv_label_set_text(label_status, "CYD Hub: capture ON");
  }, LV_EVENT_CLICKED, nullptr);

  lv_obj_add_event_cb(btn_stop, [](lv_event_t *e) {
    captureEnabled = false;
    lv_label_set_text(label_status, "CYD Hub: capture OFF");
  }, LV_EVENT_CLICKED, nullptr);
}

// ---- LVGL update helpers ----
void update_nodes_table() {
  int row = 1;
  for (auto &n : nodes) {
    if (row >= lv_table_get_row_cnt(table_nodes)) break;
    lv_table_set_cell_value(table_nodes, row, 0, n.mac.c_str());
    lv_table_set_cell_value(table_nodes, row, 1, n.ip.toString().c_str());
    lv_table_set_cell_value(table_nodes, row, 2, (n.mode == 0 ? "WiFi" : "ESPNOW"));
    lv_table_set_cell_value(table_nodes, row, 3, String(n.lastSeen / 1000).c_str());
    row++;
  }
}

// ---- Node management ----
NodeInfo* findNodeByMAC(const String &mac) {
  for (auto &n : nodes)
    if (n.mac == mac) return &n;
  return nullptr;
}

NodeInfo* findNodeByIP(const IPAddress &ip) {
  for (auto &n : nodes)
    if (n.ip == ip) return &n;
  return nullptr;
}

void acceptNodeClients() {
  WiFiClient newClient = ctrlServer.available();
  if (newClient) {
    IPAddress ip = newClient.remoteIP();
    NodeInfo *existing = findNodeByIP(ip);
    if (existing) {
      existing->ctrlClient = newClient;
    } else {
      NodeInfo n;
      n.ip = ip;
      n.mac = "";
      n.ctrlClient = newClient;
      n.mode = 0;
      n.lastSeen = millis();
      nodes.push_back(n);
    }
  }
}

void sendModeToNode(NodeInfo &node, int mode) {
  node.mode = mode;
  String json = "{\"cmd\":\"set_mode\",\"mode\":" + String(mode) + "}";
  node.ctrlClient.println(json);

  if (mode == 1) {
    String macStr = WiFi.softAPmacAddress();
    String j2 = "{\"cmd\":\"set_hub_mac\",\"mac\":\"" + macStr + "\"}";
    node.ctrlClient.println(j2);
  }
}

// ---- ESP-NOW receiver ----
void onEspNowRecv(const uint8_t *mac, const uint8_t *data, int len) {
  if (!captureEnabled) return;
  writePcapPacket(pcapFile, data, len);
  Serial.printf("ESPNOW: %.*s\n", len, data);
}

// ---- Wi-Fi JSON from nodes ----
void readNodeData() {
  for (auto &n : nodes) {
    WiFiClient &c = n.ctrlClient;
    while (c.connected() && c.available()) {
      String line = c.readStringUntil('\n');
      line.trim();
      if (!line.length()) continue;

      n.lastSeen = millis();

      if (captureEnabled)
        writePcapPacket(pcapFile, (const uint8_t*)line.c_str(), line.length());

      Serial.println(line);

      // Extract node MAC
      int macIndex = line.indexOf("\"node_mac\":\"");
      if (macIndex >= 0) {
        int start = macIndex + 12;
        int end = line.indexOf("\"", start);
        n.mac = line.substring(start, end);
      }

      // Update Wi-Fi / BLE tables
      if (line.indexOf("\"src\":\"node_wifi\"") >= 0) {
        // Wi-Fi AP row
        String ssid, bssid, rssiStr, chStr;
        int sIdx = line.indexOf("\"ssid\":\"");
        int sStart = sIdx + 8;
        int sEnd = line.indexOf("\"", sStart);
        ssid = line.substring(sEnd > sStart ? sStart : sStart, sEnd);

        int bIdx = line.indexOf("\"ap_mac\":\"");
        int bStart = bIdx + 10;
        int bEnd = line.indexOf("\"", bStart);
        bssid = line.substring(bEnd > bStart ? bStart : bStart, bEnd);

        int rIdx = line.indexOf("\"rssi\":");
        int cIdx = line.indexOf("\"channel\":");
        rssiStr = line.substring(rIdx + 7, line.indexOf(",", rIdx + 7));
        chStr = line.substring(cIdx + 10, line.indexOf(",", cIdx + 10));

        // Insert into Wi-Fi table (simple rolling)
        for (int row = 1; row < lv_table_get_row_cnt(table_wifi); row++) {
          const char *cur = lv_table_get_cell_value(table_wifi, row, 0);
          if (!cur || !strlen(cur)) {
            lv_table_set_cell_value(table_wifi, row, 0, ssid.c_str());
            lv_table_set_cell_value(table_wifi, row, 1, bssid.c_str());
            lv_table_set_cell_value(table_wifi, row, 2, rssiStr.c_str());
            lv_table_set_cell_value(table_wifi, row, 3, chStr.c_str());
            break;
          }
        }
      } else if (line.indexOf("\"src\":\"node_ble\"") >= 0) {
        String mac, rssiStr, payload;
        int mIdx = line.indexOf("\"ble_mac\":\"");
        int mStart = mIdx + 11;
        int mEnd = line.indexOf("\"", mStart);
        mac = line.substring(mEnd > mStart ? mStart : mStart, mEnd);

        int rIdx = line.indexOf("\"rssi\":");
        int pIdx = line.indexOf("\"payload\":\"");
        rssiStr = line.substring(rIdx + 7, line.indexOf(",", rIdx + 7));
        int pStart = pIdx + 11;
        int pEnd = line.indexOf("\"", pStart);
        payload = line.substring(pEnd > pStart ? pStart : pStart, pEnd);

        for (int row = 1; row < lv_table_get_row_cnt(table_ble); row++) {
          const char *cur = lv_table_get_cell_value(table_ble, row, 0);
          if (!cur || !strlen(cur)) {
            lv_table_set_cell_value(table_ble, row, 0, mac.c_str());
            lv_table_set_cell_value(table_ble, row, 1, rssiStr.c_str());
            lv_table_set_cell_value(table_ble, row, 2, payload.c_str());
            break;
          }
        }
      }
    }
  }
}

// ---- Serial commands (optional) ----
void handleSerialCommands() {
  if (!Serial.available()) return;
  String cmd = Serial.readStringUntil('\n');
  cmd.trim();

  if (cmd == "list") {
    Serial.println("Nodes:");
    for (auto &n : nodes) {
      Serial.printf("IP=%s MAC=%s mode=%d last=%lu\n",
                    n.ip.toString().c_str(),
                    n.mac.c_str(),
                    n.mode,
                    n.lastSeen);
    }
    return;
  }

  if (cmd.startsWith("set ")) {
    int firstSpace = cmd.indexOf(' ');
    int secondSpace = cmd.indexOf(' ', firstSpace + 1);
    String mac = cmd.substring(firstSpace + 1, secondSpace);
    int mode = cmd.substring(secondSpace + 1).toInt();
    NodeInfo *node = findNodeByMAC(mac);
    if (!node) {
      Serial.printf("Node %s not found\n", mac.c_str());
      return;
    }
    sendModeToNode(*node, mode);
  }
}

// ---- Setup / loop ----
void setup() {
  Serial.begin(115200);
  delay(500);

  // Display init
  gfx->begin();
  gfx->fillScreen(BLACK);

  lv_init();
  lv_disp_draw_buf_init(&draw_buf, buf1, nullptr, SCREEN_WIDTH * 40);

  static lv_disp_drv_t disp_drv;
  lv_disp_drv_init(&disp_drv);
  disp_drv.hor_res = SCREEN_WIDTH;
  disp_drv.ver_res = SCREEN_HEIGHT;
  disp_drv.flush_cb = lvgl_flush_cb;
  disp_drv.draw_buf = &draw_buf;
  lv_disp_drv_register(&disp_drv);

  setup_ui();

  // Wi-Fi AP
  WiFi.mode(WIFI_AP);
  WiFi.softAP(CTRL_SSID, CTRL_PASSWORD);
  Serial.print("CYD AP IP: ");
  Serial.println(WiFi.softAPIP());
  Serial.print("CYD MAC: ");
  Serial.println(WiFi.softAPmacAddress());

  ctrlServer.begin();

  // ESP-NOW
  esp_now_init();
  esp_now_register_recv_cb(onEspNowRecv);

  // SD
  SD.begin(SD_CS_PIN);
  pcapFile = SD.open("/wardrive.pcap", FILE_WRITE);
  pcapFile.write(PCAP_GLOBAL_HEADER, 24);
}

void loop() {
  acceptNodeClients();
  readNodeData();
  handleSerialCommands();

  update_nodes_table();
  lv_timer_handler();
  delay(5);
}