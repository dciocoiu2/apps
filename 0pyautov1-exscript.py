# manifest_json at top-level instructs packer about capabilities
manifest_json = {
  "allow_input": True,
  "allow_files": True,
  "allow_process": False,
  "allowed_paths": ["/tmp", "C:\\\\Temp"],
  "max_runtime_seconds": 20
}

def main():
    host.log("Script started")
    # move mouse to 100,100 then click
    host.move_mouse(100, 100)
    host.click(None, None, "left")
    host.type_text("Hello from script\\n")
    # read a safe file if present
    try:
        s = host.read_file("/tmp/test.txt")
        host.log("Read /tmp/test.txt length=" + str(len(s)))
    except Exception as e:
        host.log("read_file failed: " + str(e))
    return "done"