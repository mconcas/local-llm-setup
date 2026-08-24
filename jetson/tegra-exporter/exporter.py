"""Prometheus exporter for Tegra sysfs metrics that node-exporter does not cover.

Exports, in text exposition format on :9101/metrics:
  tegra_gpu_load_ratio          iGPU utilisation in [0, 1] (sysfs load is 0-1000)
  tegra_gpu_frequency_hertz     current iGPU devfreq frequency
  tegra_rail_power_watts{rail}  per-rail power from every INA3221 hwmon channel

Reads /sys only; run with the host's /sys bind-mounted read-only.
"""
import glob
import os
from http.server import BaseHTTPRequestHandler, HTTPServer

SYS = os.environ.get("SYS_ROOT", "/sys")


def read(path):
    """Return the stripped content of a sysfs file, or None when unreadable."""
    try:
        with open(path, encoding="ascii") as handle:
            return handle.read().strip()
    except OSError:
        return None


def gpu_lines():
    """Yield exposition lines for iGPU load and frequency, when present."""
    for load_path in glob.glob(f"{SYS}/devices/platform/*.gpu/load"):
        value = read(load_path)
        if value is not None:
            yield "# TYPE tegra_gpu_load_ratio gauge"
            yield f"tegra_gpu_load_ratio {int(value) / 1000}"
        break
    for freq_path in glob.glob(f"{SYS}/devices/platform/*.gpu/devfreq/*/cur_freq"):
        value = read(freq_path)
        if value is not None:
            yield "# TYPE tegra_gpu_frequency_hertz gauge"
            yield f"tegra_gpu_frequency_hertz {value}"
        break


def rail_lines():
    """Yield exposition lines for INA3221 rail power (mV * mA -> W)."""
    emitted_type = False
    for hwmon in glob.glob(f"{SYS}/class/hwmon/hwmon*"):
        if read(f"{hwmon}/name") != "ina3221":
            continue
        for label_path in glob.glob(f"{hwmon}/in*_label"):
            channel = os.path.basename(label_path)[2:-6]
            rail = read(label_path)
            millivolts = read(f"{hwmon}/in{channel}_input")
            milliamps = read(f"{hwmon}/curr{channel}_input")
            if not rail or millivolts is None or milliamps is None:
                continue
            if not emitted_type:
                yield "# TYPE tegra_rail_power_watts gauge"
                emitted_type = True
            watts = int(millivolts) * int(milliamps) / 1e6
            yield f'tegra_rail_power_watts{{rail="{rail}"}} {watts:.3f}'


class Handler(BaseHTTPRequestHandler):
    """Serve /metrics; anything else is 404."""

    def do_GET(self):
        if self.path != "/metrics":
            self.send_response(404)
            self.end_headers()
            return
        body = ("\n".join([*gpu_lines(), *rail_lines()]) + "\n").encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; version=0.0.4")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        """Silence per-request logging."""


if __name__ == "__main__":
    HTTPServer(("0.0.0.0", 9101), Handler).serve_forever()
