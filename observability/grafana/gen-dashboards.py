#!/usr/bin/env python3
"""Generate the provisioned Grafana dashboards under ./dashboards from code."""
import json, itertools, os
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "dashboards")
PROM = {"type": "prometheus", "uid": "prometheus"}
LOKI = {"type": "loki", "uid": "loki"}
_id = itertools.count(1)

def q(expr, legend="", ds=PROM, **kw):
    t = {"refId": chr(65 + kw.pop("i", 0)), "expr": expr, "datasource": ds, "legendFormat": legend}
    t.update(kw)
    return t

def panel(kind, title, targets, x, y, w, h, unit=None, ds=PROM, decimals=None, min_=None, max_=None, overrides=None, opts=None, desc=None, thresholds=None):
    fc = {"defaults": {"color": {"mode": "palette-classic"}}, "overrides": overrides or []}
    d = fc["defaults"]
    if unit: d["unit"] = unit
    if decimals is not None: d["decimals"] = decimals
    if min_ is not None: d["min"] = min_
    if max_ is not None: d["max"] = max_
    if thresholds:
        d["thresholds"] = {"mode": "absolute", "steps": thresholds}
        d["color"] = {"mode": "thresholds"}
    if kind == "timeseries":
        d["custom"] = {"lineWidth": 1, "fillOpacity": 10, "showPoints": "never", "spanNulls": True}
    p = {"id": next(_id), "type": kind, "title": title, "datasource": ds,
         "gridPos": {"x": x, "y": y, "w": w, "h": h}, "targets": targets, "fieldConfig": fc,
         "options": opts or {}}
    if desc: p["description"] = desc
    if kind == "timeseries":
        p["options"] = {"legend": {"displayMode": "list", "placement": "bottom"}, "tooltip": {"mode": "multi", "sort": "desc"}, **(opts or {})}
    if kind == "stat":
        p["options"] = {"reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False}, "colorMode": "value", "graphMode": "area", "textMode": "auto", **(opts or {})}
    return p

def row(title, y):
    return {"id": next(_id), "type": "row", "title": title, "collapsed": False, "gridPos": {"x": 0, "y": y, "w": 24, "h": 1}, "panels": []}

def dashboard(uid, title, panels, templating=None, refresh="30s", rng="now-6h", tags=()):
    return {"uid": uid, "title": title, "tags": ["local-llm", *tags], "timezone": "browser", "editable": True,
            "schemaVersion": 41, "version": 1, "refresh": refresh, "time": {"from": rng, "to": "now"},
            "templating": {"list": templating or []}, "panels": panels, "links": [
                {"type": "dashboards", "tags": ["local-llm"], "asDropdown": True, "title": "local-llm", "includeVars": False, "keepTime": True}]}

def var_query(name, label, query, ds=PROM, multi=True, all_=True, current=None):
    v = {"name": name, "label": label, "type": "query", "datasource": ds, "query": query, "refresh": 2,
         "multi": multi, "includeAll": all_, "sort": 1}
    if current is not None:
        v["current"] = {"text": current, "value": current}
    return v

BIN = {"mode": "absolute", "steps": [{"color": "red", "value": None}, {"color": "green", "value": 1}]}
GYR = lambda a, b: [{"color": "green", "value": None}, {"color": "orange", "value": a}, {"color": "red", "value": b}]

# ── LLM service ──────────────────────────────────────────────────
J = 'job="llama-server"'
llm = [
    panel("stat", "llama-server up", [q(f'up{{{J}}}')], 0, 0, 4, 4, thresholds=BIN["steps"],
          opts={"graphMode": "none"}, overrides=[{"matcher": {"id": "byName", "options": "Value"}, "properties": [{"id": "mappings", "value": [{"type": "value", "options": {"0": {"text": "DOWN"}, "1": {"text": "UP"}}}]}]}]),
    panel("stat", "Requests processing", [q(f'llamacpp:requests_processing{{{J}}}')], 4, 0, 4, 4, decimals=0),
    panel("stat", "Requests queued", [q(f'llamacpp:requests_deferred{{{J}}}')], 8, 0, 4, 4, decimals=0, thresholds=GYR(1, 3)),
    panel("stat", "Decode speed (1h)", [q(f'increase(llamacpp:tokens_predicted_total{{{J}}}[1h]) / increase(llamacpp:tokens_predicted_seconds_total{{{J}}}[1h])')], 12, 0, 4, 4, unit="short", decimals=1, desc="Generated tokens per second of generation time over the last hour", opts={"graphMode": "none"}),
    panel("stat", "Prompt speed (1h)", [q(f'increase(llamacpp:prompt_tokens_total{{{J}}}[1h]) / increase(llamacpp:prompt_seconds_total{{{J}}}[1h])')], 16, 0, 4, 4, unit="short", decimals=0, desc="Uncached prompt tokens per second of prompt-processing time over the last hour", opts={"graphMode": "none"}),
    panel("stat", "Longest sequence seen", [q(f'llamacpp:n_tokens_max{{{J}}}')], 20, 0, 4, 4, unit="short", decimals=0, desc="Largest prompt+generation length observed since start; compare against CTX_SIZE"),

    panel("timeseries", "Token throughput", [
        q(f'rate(llamacpp:tokens_predicted_total{{{J}}}[$__rate_interval])', "generated tok/s"),
        q(f'rate(llamacpp:prompt_tokens_total{{{J}}}[$__rate_interval])', "prompt tok/s", i=1),
        q(f'rate(llamacpp:prompt_tokens_cached_total{{{J}}}[$__rate_interval])', "cached prompt tok/s", i=2),
    ], 0, 4, 12, 8, unit="short", desc="Wall-clock averaged over the scrape window, so idle time lowers the value"),
    panel("timeseries", "Effective speed while busy", [
        q(f'rate(llamacpp:tokens_predicted_total{{{J}}}[$__rate_interval]) / rate(llamacpp:tokens_predicted_seconds_total{{{J}}}[$__rate_interval])', "decode tok/s"),
        q(f'rate(llamacpp:prompt_tokens_total{{{J}}}[$__rate_interval]) / rate(llamacpp:prompt_seconds_total{{{J}}}[$__rate_interval])', "prompt tok/s", i=1),
    ], 12, 4, 12, 8, unit="short", desc="Tokens divided by the time llama.cpp spent in that phase; the true model speed", overrides=[{"matcher": {"id": "byName", "options": "prompt tok/s"}, "properties": [{"id": "custom.axisPlacement", "value": "right"}]}]),

    panel("timeseries", "Requests", [
        q(f'llamacpp:requests_processing{{{J}}}', "processing"),
        q(f'llamacpp:requests_deferred{{{J}}}', "queued", i=1),
        q(f'llamacpp:n_busy_slots_per_decode{{{J}}}', "busy slots / decode", i=2),
    ], 0, 12, 8, 8, decimals=1),
    panel("timeseries", "Time share", [
        q(f'rate(llamacpp:tokens_predicted_seconds_total{{{J}}}[$__rate_interval])', "generating"),
        q(f'rate(llamacpp:prompt_seconds_total{{{J}}}[$__rate_interval])', "prompt processing", i=1),
    ], 8, 12, 8, 8, unit="percentunit", min_=0, max_=1, desc="Fraction of wall-clock the server spent in each phase", opts={}),
    panel("timeseries", "Prompt cache hit ratio", [
        q(f'rate(llamacpp:prompt_tokens_cached_total{{{J}}}[$__rate_interval]) / (rate(llamacpp:prompt_tokens_cached_total{{{J}}}[$__rate_interval]) + rate(llamacpp:prompt_tokens_total{{{J}}}[$__rate_interval]))', "cached / total prompt tokens"),
    ], 16, 12, 8, 8, unit="percentunit", min_=0, max_=1),

    panel("timeseries", "Tokens per hour", [
        q(f'increase(llamacpp:tokens_predicted_total{{{J}}}[1h])', "generated"),
        q(f'increase(llamacpp:prompt_tokens_total{{{J}}}[1h])', "prompt (uncached)", i=1),
    ], 0, 20, 12, 8, unit="short"),
    panel("timeseries", "llama_decode() calls", [q(f'rate(llamacpp:n_decode_total{{{J}}}[$__rate_interval])', "decode/s")], 12, 20, 12, 8, unit="ops"),
    panel("logs", "llama-server log", [q('{container="llama-server"}', ds=LOKI)], 0, 28, 24, 10, ds=LOKI,
          opts={"showTime": True, "wrapLogMessage": True, "sortOrder": "Descending", "dedupStrategy": "none", "enableLogDetails": True}),
]
json.dump(dashboard("llm-service", "LLM service", llm, tags=["llama.cpp"]), open(f"{OUT}/llm-service.json", "w"), indent=2)

# ── nginx ────────────────────────────────────────────────────────
NX = '{container="llama-proxy"} |= "\\"status\\":" | json'
NXC = NX + ' | client_cn=~"$client_cn" | uri=~"$uri"'
cn_var = {"name": "client_cn", "label": "Client CN", "type": "textbox", "query": ".*", "current": {"text": ".*", "value": ".*"}}
uri_var = {"name": "uri", "label": "URI regex", "type": "textbox", "query": ".*", "current": {"text": ".*", "value": ".*"}}
nginx = [
    panel("stat", "nginx up", [q('nginx_up')], 0, 0, 4, 4, thresholds=BIN["steps"], opts={"graphMode": "none"},
          overrides=[{"matcher": {"id": "byName", "options": "Value"}, "properties": [{"id": "mappings", "value": [{"type": "value", "options": {"0": {"text": "DOWN"}, "1": {"text": "UP"}}}]}]}]),
    panel("stat", "Active connections", [q('nginx_connections_active')], 4, 0, 4, 4, decimals=0),
    panel("stat", "Requests / min", [q('rate(nginx_http_requests_total[$__rate_interval]) * 60')], 8, 0, 4, 4, decimals=1),
    panel("stat", "5xx last 1h", [q(f'sum(count_over_time({NX} | status >= 500 [1h])) or vector(0)', ds=LOKI)], 12, 0, 4, 4, ds=LOKI, decimals=0, thresholds=GYR(1, 10)),
    panel("stat", "4xx last 1h", [q(f'sum(count_over_time({NX} | status >= 400 | status < 500 [1h])) or vector(0)', ds=LOKI)], 16, 0, 4, 4, ds=LOKI, decimals=0, thresholds=GYR(10, 100)),
    panel("stat", "p95 request time 1h", [q(f'quantile_over_time(0.95, {NX} | unwrap request_time [1h]) by ()', ds=LOKI)], 20, 0, 4, 4, ds=LOKI, unit="s", decimals=1),

    panel("timeseries", "Requests by status", [q('sum by (status) (rate({container="llama-proxy", status=~".+"}[$__auto])) * 60', "{{status}}", ds=LOKI)], 0, 4, 12, 8, ds=LOKI, unit="reqpm",
          overrides=[{"matcher": {"id": "byRegexp", "options": "^5.."}, "properties": [{"id": "color", "value": {"mode": "fixed", "fixedColor": "red"}}]},
                     {"matcher": {"id": "byRegexp", "options": "^4.."}, "properties": [{"id": "color", "value": {"mode": "fixed", "fixedColor": "orange"}}]},
                     {"matcher": {"id": "byRegexp", "options": "^2.."}, "properties": [{"id": "color", "value": {"mode": "fixed", "fixedColor": "green"}}]}]),
    panel("timeseries", "Requests by client certificate", [q(f'sum by (client_cn) (rate({NXC} | label_format client_cn="{{{{ if .client_cn }}}}{{{{ .client_cn }}}}{{{{ else }}}}(rejected, no certificate){{{{ end }}}}" [$__auto])) * 60', "{{client_cn}}", ds=LOKI)], 12, 4, 12, 8, ds=LOKI, unit="reqpm",
          overrides=[{"matcher": {"id": "byName", "options": "(rejected, no certificate)"}, "properties": [{"id": "color", "value": {"mode": "fixed", "fixedColor": "red"}}]}]),

    panel("timeseries", "Request time", [
        q(f'quantile_over_time(0.50, {NXC} | unwrap request_time [$__auto]) by ()', "p50", ds=LOKI),
        q(f'quantile_over_time(0.95, {NXC} | unwrap request_time [$__auto]) by ()', "p95", ds=LOKI, i=1),
        q(f'max_over_time({NXC} | unwrap request_time [$__auto]) by ()', "max", ds=LOKI, i=2),
    ], 0, 12, 12, 8, ds=LOKI, unit="s", desc="Full request duration at nginx, streaming responses included"),
    panel("timeseries", "Bytes", [
        q(f'sum(rate({NXC} | unwrap bytes_sent [$__auto]))', "sent", ds=LOKI),
        q(f'sum(rate({NXC} | unwrap request_length [$__auto]))', "received", ds=LOKI, i=1),
    ], 12, 12, 12, 8, ds=LOKI, unit="Bps"),

    panel("timeseries", "Connections", [
        q('nginx_connections_active', "active"), q('nginx_connections_reading', "reading", i=1),
        q('nginx_connections_writing', "writing", i=2), q('nginx_connections_waiting', "waiting", i=3),
    ], 0, 20, 12, 8, decimals=0),
    panel("timeseries", "Accepted vs handled", [
        q('rate(nginx_connections_accepted[$__rate_interval])', "accepted/s"),
        q('rate(nginx_connections_handled[$__rate_interval])', "handled/s", i=1),
    ], 12, 20, 12, 8, unit="ops", desc="A gap means nginx dropped connections (worker_connections exhausted)"),

    panel("table", "Top URIs (range)", [q(f'topk(10, sum by (uri, method) (count_over_time({NXC} [$__range])))', ds=LOKI, instant=True, format="table")], 0, 28, 12, 9, ds=LOKI,
          opts={"sortBy": [{"displayName": "Value", "desc": True}]},
          overrides=[{"matcher": {"id": "byName", "options": "Time"}, "properties": [{"id": "custom.hidden", "value": True}]},
                     {"matcher": {"id": "byName", "options": "Value #A"}, "properties": [{"id": "displayName", "value": "requests"}, {"id": "custom.width", "value": 110}]}]),
    panel("table", "Top user agents (range)", [q(f'topk(10, sum by (user_agent) (count_over_time({NXC} [$__range])))', ds=LOKI, instant=True, format="table")], 12, 28, 12, 9, ds=LOKI,
          opts={"sortBy": [{"displayName": "Value", "desc": True}]},
          overrides=[{"matcher": {"id": "byName", "options": "Time"}, "properties": [{"id": "custom.hidden", "value": True}]},
                     {"matcher": {"id": "byName", "options": "Value #A"}, "properties": [{"id": "displayName", "value": "requests"}, {"id": "custom.width", "value": 110}]}]),
    panel("logs", "Access log", [q(f'{NXC} | line_format "{{{{.status}}}} {{{{.method}}}} {{{{.uri}}}} {{{{.request_time}}}}s cn={{{{.client_cn}}}} {{{{.client}}}} {{{{.user_agent}}}}"', ds=LOKI)], 0, 37, 24, 10, ds=LOKI,
          opts={"showTime": True, "wrapLogMessage": False, "sortOrder": "Descending", "dedupStrategy": "none", "enableLogDetails": True}),
    panel("logs", "nginx error log", [q('{container="llama-proxy"} != "\\"status\\":"', ds=LOKI)], 0, 47, 24, 8, ds=LOKI,
          opts={"showTime": True, "wrapLogMessage": True, "sortOrder": "Descending", "dedupStrategy": "none", "enableLogDetails": True}),
]
json.dump(dashboard("nginx", "nginx (mTLS front end)", nginx, templating=[cn_var, uri_var], tags=["nginx"]), open(f"{OUT}/nginx.json", "w"), indent=2)

# ── GPU + host + containers ──────────────────────────────────────
G = 'job="dcgm"'
proj = var_query("project", "Compose project", 'label_values(container_last_seen{container_label_com_docker_compose_project=~".+"}, container_label_com_docker_compose_project)', multi=False, all_=False, current="local-llm-setup")
CF = 'container_label_com_docker_compose_project="$project", name=~".+"'
host = [
    row("GPU", 0),
    panel("stat", "GPU utilisation", [q(f'DCGM_FI_DEV_GPU_UTIL{{{G}}}', "{{modelName}}")], 0, 1, 4, 4, unit="percent", min_=0, max_=100, thresholds=[{"color": "green", "value": None}]),
    panel("stat", "VRAM used", [q(f'DCGM_FI_DEV_FB_USED{{{G}}} * 1024 * 1024')], 4, 1, 4, 4, unit="bytes", decimals=1),
    panel("stat", "VRAM free", [q(f'DCGM_FI_DEV_FB_FREE{{{G}}} * 1024 * 1024')], 8, 1, 4, 4, unit="bytes", decimals=1, thresholds=[{"color": "red", "value": None}, {"color": "orange", "value": 1e9}, {"color": "green", "value": 3e9}]),
    panel("stat", "GPU temperature", [q(f'DCGM_FI_DEV_GPU_TEMP{{{G}}}')], 12, 1, 4, 4, unit="celsius", thresholds=GYR(75, 85)),
    panel("stat", "Power draw", [q(f'DCGM_FI_DEV_POWER_USAGE{{{G}}}')], 16, 1, 4, 4, unit="watt", decimals=0),
    panel("stat", "Energy 24h", [q(f'increase(DCGM_FI_DEV_TOTAL_ENERGY_CONSUMPTION{{{G}}}[24h]) / 1000 / 3600', "")], 20, 1, 4, 4, unit="watth", decimals=2, desc="Counter is in mJ"),
    panel("timeseries", "GPU activity", [
        q(f'DCGM_FI_DEV_GPU_UTIL{{{G}}}', "util"),
        q(f'DCGM_FI_PROF_GR_ENGINE_ACTIVE{{{G}}} * 100', "graphics engine active", i=1),
        q(f'DCGM_FI_PROF_PIPE_TENSOR_ACTIVE{{{G}}} * 100', "tensor pipe active", i=2),
        q(f'DCGM_FI_PROF_DRAM_ACTIVE{{{G}}} * 100', "DRAM active", i=3),
        q(f'DCGM_FI_DEV_MEM_COPY_UTIL{{{G}}}', "mem copy util", i=4),
    ], 0, 5, 12, 8, unit="percent", min_=0, max_=100),
    panel("timeseries", "VRAM", [
        q(f'DCGM_FI_DEV_FB_USED{{{G}}} * 1024 * 1024', "used"),
        q(f'DCGM_FI_DEV_FB_FREE{{{G}}} * 1024 * 1024', "free", i=1),
        q(f'DCGM_FI_DEV_FB_RESERVED{{{G}}} * 1024 * 1024', "reserved", i=2),
    ], 12, 5, 12, 8, unit="bytes", min_=0),
    panel("timeseries", "Power and temperature", [
        q(f'DCGM_FI_DEV_POWER_USAGE{{{G}}}', "power (W)"),
        q(f'DCGM_FI_DEV_GPU_TEMP{{{G}}}', "GPU temp (C)", i=1),
        q(f'DCGM_FI_DEV_MEMORY_TEMP{{{G}}}', "memory temp (C)", i=2),
    ], 0, 13, 8, 8, overrides=[{"matcher": {"id": "byRegexp", "options": ".*temp.*"}, "properties": [{"id": "unit", "value": "celsius"}, {"id": "custom.axisPlacement", "value": "right"}]},
                               {"matcher": {"id": "byName", "options": "power (W)"}, "properties": [{"id": "unit", "value": "watt"}]}]),
    panel("timeseries", "Clocks", [q(f'DCGM_FI_DEV_SM_CLOCK{{{G}}}', "SM"), q(f'DCGM_FI_DEV_MEM_CLOCK{{{G}}}', "memory", i=1)], 8, 13, 8, 8, unit="suffix: MHz"),
    panel("timeseries", "PCIe", [q(f'DCGM_FI_PROF_PCIE_RX_BYTES{{{G}}}', "rx"), q(f'DCGM_FI_PROF_PCIE_TX_BYTES{{{G}}}', "tx", i=1), q(f'increase(DCGM_FI_DEV_PCIE_REPLAY_COUNTER{{{G}}}[$__rate_interval])', "replays", i=2)], 16, 13, 8, 8, unit="Bps",
          overrides=[{"matcher": {"id": "byName", "options": "replays"}, "properties": [{"id": "unit", "value": "short"}, {"id": "custom.axisPlacement", "value": "right"}]}]),

    row("Host", 21),
    panel("timeseries", "CPU", [q('100 - avg(rate(node_cpu_seconds_total{mode="idle"}[$__rate_interval])) * 100', "busy"), q('avg(rate(node_cpu_seconds_total{mode="iowait"}[$__rate_interval])) * 100', "iowait", i=1)], 0, 22, 8, 8, unit="percent", min_=0, max_=100, desc="Average over all cores"),
    panel("timeseries", "Memory", [
        q('node_memory_MemTotal_bytes - node_memory_MemAvailable_bytes', "used"),
        q('node_memory_Cached_bytes + node_memory_Buffers_bytes', "cache+buffers", i=1),
        q('node_memory_MemTotal_bytes', "total", i=2),
        q('node_memory_SwapTotal_bytes - node_memory_SwapFree_bytes', "swap used", i=3),
    ], 8, 22, 8, 8, unit="bytes", min_=0, desc="Model weights read via mmap show up as page cache"),
    panel("timeseries", "Load", [q('node_load1', "1m"), q('node_load5', "5m", i=1), q('node_load15', "15m", i=2)], 16, 22, 8, 8, decimals=1, desc="Divide by the core count shown in the CPU panel description"),
    panel("timeseries", "Disk I/O", [q('sum by (device) (rate(node_disk_read_bytes_total{device!~"loop.*|dm-.*"}[$__rate_interval]))', "read {{device}}"), q('- sum by (device) (rate(node_disk_written_bytes_total{device!~"loop.*|dm-.*"}[$__rate_interval]))', "write {{device}}", i=1)], 0, 30, 8, 8, unit="Bps"),
    panel("timeseries", "Network", [q('sum by (device) (rate(node_network_receive_bytes_total{device!~"lo|veth.*|br-.*|docker.*"}[$__rate_interval]) * 8)', "rx {{device}}"), q('- sum by (device) (rate(node_network_transmit_bytes_total{device!~"lo|veth.*|br-.*|docker.*"}[$__rate_interval]) * 8)', "tx {{device}}", i=1)], 8, 30, 8, 8, unit="bps"),
    panel("bargauge", "Filesystem usage", [q('1 - node_filesystem_avail_bytes{fstype!~"tmpfs|overlay|squashfs"} / node_filesystem_size_bytes', "{{mountpoint}}", instant=True)], 16, 30, 8, 8, unit="percentunit", min_=0, max_=1, thresholds=GYR(0.8, 0.9),
          opts={"orientation": "horizontal", "displayMode": "gradient", "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False}}),

    row("Containers", 38),
    panel("timeseries", "Container CPU", [q(f'sum by (name) (rate(container_cpu_usage_seconds_total{{{CF}}}[$__rate_interval])) * 100', "{{name}}")], 0, 39, 12, 8, unit="percent", desc="100% = one core"),
    panel("timeseries", "Container memory (working set)", [q(f'max by (name) (container_memory_working_set_bytes{{{CF}}})', "{{name}}")], 12, 39, 12, 8, unit="bytes"),
    panel("timeseries", "Container network", [q(f'sum by (name) (rate(container_network_receive_bytes_total{{{CF}}}[$__rate_interval]))', "rx {{name}}"), q(f'- sum by (name) (rate(container_network_transmit_bytes_total{{{CF}}}[$__rate_interval]))', "tx {{name}}", i=1)], 0, 47, 12, 11, unit="Bps"),
    panel("timeseries", "Container disk I/O", [q(f'sum by (name) (rate(container_fs_reads_total{{{CF}}}[$__rate_interval]))', "read {{name}}"), q(f'- sum by (name) (rate(container_fs_writes_total{{{CF}}}[$__rate_interval]))', "write {{name}}", i=1)], 12, 47, 12, 11, unit="iops"),
]
json.dump(dashboard("gpu-host", "GPU, host and containers", host, templating=[proj], tags=["gpu", "host"]), open(f"{OUT}/gpu-host.json", "w"), indent=2)

# ── Logs ─────────────────────────────────────────────────────────
cvar = var_query("container", "Container", 'label_values(container)', ds=LOKI, current="All")
svar = {"name": "search", "label": "Search", "type": "textbox", "query": "", "current": {"text": "", "value": ""}}
logs = [
    panel("timeseries", "Log volume", [q('sum by (container) (count_over_time({container=~"$container"} |~ "$search" [$__auto]))', "{{container}}", ds=LOKI)], 0, 0, 24, 7, ds=LOKI, decimals=0),
    panel("logs", "Logs", [q('{container=~"$container"} |~ "$search"', ds=LOKI)], 0, 7, 24, 22, ds=LOKI,
          opts={"showTime": True, "showLabels": True, "wrapLogMessage": True, "prettifyLogMessage": False, "sortOrder": "Descending", "dedupStrategy": "none", "enableLogDetails": True}),
]
json.dump(dashboard("logs", "Logs", logs, templating=[cvar, svar], tags=["logs"], rng="now-1h"), open(f"{OUT}/logs.json", "w"), indent=2)
print("dashboards written to", OUT)
