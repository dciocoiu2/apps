// place at very begining of sketch

// =========================================================
// M5Launcher App Metadata (required)
// =========================================================
extern "C" {
  const char* m5launcher_app_name    = "CYD Wardrive Hub";
  const char* m5launcher_app_author  = "David";
  const char* m5launcher_app_version = "1.0";
}

// =========================================================
// M5Launcher Exit Hook (required)
// =========================================================
extern "C" void m5launcher_app_exit() {
  WiFi.softAPdisconnect(true);
  esp_now_deinit();
  SD.end();
}