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
NXR = NXC + ' | route=~"$route" | route!=""'
NXU = NXR + ' | usage_input=~"[0-9]+" | usage_output=~"[0-9]+"'
route_var = {"name": "route", "label": "Route", "type": "custom", "query": ".*,local,sidecar", "current": {"text": ".*", "value": ".*"},
             "options": [{"text": ".*", "value": ".*", "selected": True}, {"text": "local", "value": "local", "selected": False}, {"text": "sidecar", "value": "sidecar", "selected": False}]}
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

    row("Routing", 20),
    panel("timeseries", "Requests by route", [q(f'sum by (route) (rate({NXR} [$__auto])) * 60', "{{route}}", ds=LOKI)], 0, 21, 8, 8, ds=LOKI, unit="reqpm"),
    panel("timeseries", "Requests by model", [q(f'sum by (model) (rate({NXR} [$__auto])) * 60', "{{model}}", ds=LOKI)], 8, 21, 8, 8, ds=LOKI, unit="reqpm"),
    panel("timeseries", "Upstream status by route", [q(f'sum by (route, upstream_status) (rate({NXR} [$__auto])) * 60', "{{route}} {{upstream_status}}", ds=LOKI)], 16, 21, 8, 8, ds=LOKI, unit="reqpm",
          overrides=[{"matcher": {"id": "byRegexp", "options": ".* 5.."}, "properties": [{"id": "color", "value": {"mode": "fixed", "fixedColor": "red"}}]},
                     {"matcher": {"id": "byRegexp", "options": ".* 4.."}, "properties": [{"id": "color", "value": {"mode": "fixed", "fixedColor": "orange"}}]}]),
    panel("timeseries", "p95 request time by route", [q(f'quantile_over_time(0.95, {NXR} | unwrap request_time [$__auto]) by (route)', "{{route}}", ds=LOKI)], 0, 29, 8, 8, ds=LOKI, unit="s", desc="Full duration at nginx, streaming included"),
    panel("timeseries", "p95 time to upstream headers by route", [q(f'quantile_over_time(0.95, {NXR} | upstream_header_time=~"[0-9.]+" | unwrap upstream_header_time [$__auto]) by (route)', "{{route}}", ds=LOKI)], 8, 29, 8, 8, ds=LOKI, unit="s",
          desc="Connect plus time until the backend sent response headers. Not first-token time: llama.cpp sends headers before prompt processing"),
    panel("timeseries", "llama.cpp timings (p95)", [
        q(f'quantile_over_time(0.95, {NXR} | usage_prompt_ms=~"[0-9]+" | unwrap usage_prompt_ms [$__auto]) by (route)', "prompt {{route}}", ds=LOKI),
        q(f'quantile_over_time(0.95, {NXR} | usage_predicted_ms=~"[0-9]+" | unwrap usage_predicted_ms [$__auto]) by (route)', "generation {{route}}", ds=LOKI, i=1),
    ], 16, 29, 8, 8, ds=LOKI, unit="ms", desc="Backend-reported prompt-processing and generation time per request; only legs served by llama.cpp report it"),
    panel("timeseries", "Tokens per minute by route", [
        q(f'sum by (route) (sum_over_time({NXU} | unwrap usage_input [$__auto])) * 60', "input {{route}}", ds=LOKI),
        q(f'sum by (route) (sum_over_time({NXU} | unwrap usage_output [$__auto])) * 60', "output {{route}}", ds=LOKI, i=1),
        q(f'sum by (route) (sum_over_time({NXU} | usage_cache_read=~"[0-9]+" | unwrap usage_cache_read [$__auto])) * 60', "cache read {{route}}", ds=LOKI, i=2),
        q(f'sum by (route) (sum_over_time({NXU} | usage_cache_creation=~"[0-9]+" | unwrap usage_cache_creation [$__auto])) * 60', "cache creation {{route}}", ds=LOKI, i=3),
    ], 0, 37, 12, 8, ds=LOKI, unit="short", desc="As reported by each backend in the response usage block; Anthropic input_tokens exclude cached tokens, OpenAI-format prompt_tokens include them"),
    panel("timeseries", "Cache read share by route", [
        q(f'sum by (route) (sum_over_time({NXU} | usage_cache_read=~"[0-9]+" | unwrap usage_cache_read [$__auto])) / (sum by (route) (sum_over_time({NXU} | unwrap usage_input [$__auto])) + sum by (route) (sum_over_time({NXU} | usage_cache_read=~"[0-9]+" | unwrap usage_cache_read [$__auto])))', "{{route}}", ds=LOKI),
    ], 12, 37, 12, 8, ds=LOKI, unit="percentunit", min_=0, max_=1, desc="llama.cpp reports cache_read_input_tokens in Anthropic-format responses"),
    panel("table", "Tokens by client and model (range)", [
        q(f'sum by (client_cn, route, model) (sum_over_time({NXU} | unwrap usage_input [$__range]))', ds=LOKI, instant=True, format="table"),
        q(f'sum by (client_cn, route, model) (sum_over_time({NXU} | unwrap usage_output [$__range]))', ds=LOKI, instant=True, format="table", i=1),
        q(f'sum by (client_cn, route, model) (count_over_time({NXU} [$__range]))', ds=LOKI, instant=True, format="table", i=2),
    ], 0, 45, 24, 9, ds=LOKI, opts={"sortBy": [{"displayName": "input tokens", "desc": True}]},
          overrides=[{"matcher": {"id": "byName", "options": "Time"}, "properties": [{"id": "custom.hidden", "value": True}]},
                     {"matcher": {"id": "byName", "options": "Value #A"}, "properties": [{"id": "displayName", "value": "input tokens"}, {"id": "custom.width", "value": 130}]},
                     {"matcher": {"id": "byName", "options": "Value #B"}, "properties": [{"id": "displayName", "value": "output tokens"}, {"id": "custom.width", "value": 130}]},
                     {"matcher": {"id": "byName", "options": "Value #C"}, "properties": [{"id": "displayName", "value": "requests"}, {"id": "custom.width", "value": 110}]}]),

    row("Connections", 54),
    panel("timeseries", "Connections", [
        q('nginx_connections_active', "active"), q('nginx_connections_reading', "reading", i=1),
        q('nginx_connections_writing', "writing", i=2), q('nginx_connections_waiting', "waiting", i=3),
    ], 0, 55, 12, 8, decimals=0),
    panel("timeseries", "Accepted vs handled", [
        q('rate(nginx_connections_accepted[$__rate_interval])', "accepted/s"),
        q('rate(nginx_connections_handled[$__rate_interval])', "handled/s", i=1),
    ], 12, 55, 12, 8, unit="ops", desc="A gap means nginx dropped connections (worker_connections exhausted)"),

    panel("table", "Top URIs (range)", [q(f'topk(10, sum by (uri, method) (count_over_time({NXC} [$__range])))', ds=LOKI, instant=True, format="table")], 0, 63, 12, 9, ds=LOKI,
          opts={"sortBy": [{"displayName": "Value", "desc": True}]},
          overrides=[{"matcher": {"id": "byName", "options": "Time"}, "properties": [{"id": "custom.hidden", "value": True}]},
                     {"matcher": {"id": "byName", "options": "Value #A"}, "properties": [{"id": "displayName", "value": "requests"}, {"id": "custom.width", "value": 110}]}]),
    panel("table", "Top user agents (range)", [q(f'topk(10, sum by (user_agent) (count_over_time({NXC} [$__range])))', ds=LOKI, instant=True, format="table")], 12, 63, 12, 9, ds=LOKI,
          opts={"sortBy": [{"displayName": "Value", "desc": True}]},
          overrides=[{"matcher": {"id": "byName", "options": "Time"}, "properties": [{"id": "custom.hidden", "value": True}]},
                     {"matcher": {"id": "byName", "options": "Value #A"}, "properties": [{"id": "displayName", "value": "requests"}, {"id": "custom.width", "value": 110}]}]),
    panel("logs", "Access log", [q(f'{NXC} | line_format "{{{{.status}}}} {{{{.method}}}} {{{{.uri}}}} {{{{.request_time}}}}s cn={{{{.client_cn}}}} {{{{.client}}}} {{{{.user_agent}}}}"', ds=LOKI)], 0, 72, 24, 10, ds=LOKI,
          opts={"showTime": True, "wrapLogMessage": False, "sortOrder": "Descending", "dedupStrategy": "none", "enableLogDetails": True}),
    panel("logs", "nginx error log", [q('{container="llama-proxy"} != "\\"status\\":"', ds=LOKI)], 0, 82, 24, 8, ds=LOKI,
          opts={"showTime": True, "wrapLogMessage": True, "sortOrder": "Descending", "dedupStrategy": "none", "enableLogDetails": True}),
]
json.dump(dashboard("nginx", "nginx (mTLS front end)", nginx, templating=[cn_var, uri_var, route_var], tags=["nginx"]), open(f"{OUT}/nginx.json", "w"), indent=2)

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


# ── Jetson sidecar ───────────────────────────────────────────────
JL = 'job="jetson-llama"'
JN = 'job="jetson-node"'
JX = 'job="jetson-nginx"'
jetson = [
    panel("stat", "llama-server up", [q(f'up{{{JL}}}')], 0, 0, 4, 4, thresholds=BIN["steps"], opts={"graphMode": "none"},
          overrides=[{"matcher": {"id": "byName", "options": "Value"}, "properties": [{"id": "mappings", "value": [{"type": "value", "options": {"0": {"text": "DOWN"}, "1": {"text": "UP"}}}]}]}]),
    panel("stat", "nginx up", [q(f'nginx_up{{{JX}}}')], 4, 0, 4, 4, thresholds=BIN["steps"], opts={"graphMode": "none"},
          overrides=[{"matcher": {"id": "byName", "options": "Value"}, "properties": [{"id": "mappings", "value": [{"type": "value", "options": {"0": {"text": "DOWN"}, "1": {"text": "UP"}}}]}]}]),
    panel("stat", "GPU load", [q('tegra_gpu_load_ratio * 100')], 8, 0, 4, 4, unit="percent", min_=0, max_=100, decimals=0),
    panel("stat", "GPU frequency", [q('tegra_gpu_frequency_hertz')], 12, 0, 4, 4, unit="hertz", decimals=0,
          desc="306 MHz idle floor; 1020 MHz max in 15 W mode, more under MAXN_SUPER"),
    panel("stat", "Module power", [q('tegra_rail_power_watts{rail="VDD_IN"}')], 16, 0, 4, 4, unit="watt", decimals=1, thresholds=GYR(13, 22)),
    panel("stat", "GPU temperature", [q(f'node_thermal_zone_temp{{{JN}, type="gpu-thermal"}}')], 20, 0, 4, 4, unit="celsius", decimals=0, thresholds=GYR(75, 90)),

    panel("timeseries", "Token throughput", [
        q(f'rate(llamacpp:tokens_predicted_total{{{JL}}}[$__rate_interval])', "generated tok/s"),
        q(f'rate(llamacpp:prompt_tokens_total{{{JL}}}[$__rate_interval])', "prompt tok/s", i=1),
        q(f'rate(llamacpp:prompt_tokens_cached_total{{{JL}}}[$__rate_interval])', "cached prompt tok/s", i=2),
    ], 0, 4, 12, 8, unit="short", desc="Wall-clock averaged over the scrape window, so idle time lowers the value"),
    panel("timeseries", "Effective speed while busy", [
        q(f'rate(llamacpp:tokens_predicted_total{{{JL}}}[$__rate_interval]) / rate(llamacpp:tokens_predicted_seconds_total{{{JL}}}[$__rate_interval])', "decode tok/s"),
        q(f'rate(llamacpp:prompt_tokens_total{{{JL}}}[$__rate_interval]) / rate(llamacpp:prompt_seconds_total{{{JL}}}[$__rate_interval])', "prompt tok/s", i=1),
    ], 12, 4, 12, 8, unit="short", desc="Tokens divided by the time llama.cpp spent in that phase; the true model speed",
          overrides=[{"matcher": {"id": "byName", "options": "prompt tok/s"}, "properties": [{"id": "custom.axisPlacement", "value": "right"}]}]),

    panel("timeseries", "GPU", [
        q('tegra_gpu_load_ratio * 100', "load %"),
        q('tegra_gpu_frequency_hertz', "frequency", i=1),
    ], 0, 12, 8, 8, unit="percent", min_=0,
          overrides=[{"matcher": {"id": "byName", "options": "frequency"}, "properties": [{"id": "unit", "value": "hertz"}, {"id": "custom.axisPlacement", "value": "right"}]}]),
    panel("timeseries", "Power rails", [q('tegra_rail_power_watts', "{{rail}}")], 8, 12, 8, 8, unit="watt", min_=0,
          desc="INA3221 channels; VDD_IN is the whole module"),
    panel("timeseries", "Temperatures", [
        q(f'node_thermal_zone_temp{{{JN}, type=~"cpu-thermal|gpu-thermal|tj-thermal|soc[0-2]-thermal"}}', "{{type}}"),
    ], 16, 12, 8, 8, unit="celsius"),

    panel("timeseries", "Unified memory", [
        q(f'node_memory_MemTotal_bytes{{{JN}}} - node_memory_MemAvailable_bytes{{{JN}}}', "used"),
        q(f'node_memory_Cached_bytes{{{JN}}} + node_memory_Buffers_bytes{{{JN}}}', "cache+buffers", i=1),
        q(f'node_memory_MemTotal_bytes{{{JN}}}', "total", i=2),
        q(f'node_memory_SwapTotal_bytes{{{JN}}} - node_memory_SwapFree_bytes{{{JN}}}', "swap used", i=3),
    ], 0, 20, 8, 8, unit="bytes", min_=0, desc="CPU and iGPU share this memory; weights are streamed with direct I/O (no page-cache copy)"),
    panel("timeseries", "CPU", [
        q(f'100 - avg(rate(node_cpu_seconds_total{{{JN}, mode="idle"}}[$__rate_interval])) * 100', "busy"),
        q(f'avg(rate(node_cpu_seconds_total{{{JN}, mode="iowait"}}[$__rate_interval])) * 100', "iowait", i=1),
    ], 8, 20, 8, 8, unit="percent", min_=0, max_=100, desc="Average over all cores"),
    panel("timeseries", "Requests", [
        q(f'llamacpp:requests_processing{{{JL}}}', "processing"),
        q(f'llamacpp:requests_deferred{{{JL}}}', "queued", i=1),
        q(f'rate(nginx_http_requests_total{{{JX}}}[$__rate_interval]) * 60', "nginx req/min", i=2),
    ], 16, 20, 8, 8, decimals=1,
          overrides=[{"matcher": {"id": "byName", "options": "nginx req/min"}, "properties": [{"id": "custom.axisPlacement", "value": "right"}]}]),
]
json.dump(dashboard("jetson-sidecar", "Jetson sidecar", jetson, tags=["jetson"], refresh="30s"), open(f"{OUT}/jetson-sidecar.json", "w"), indent=2)

# ── Logs ─────────────────────────────────────────────────────────
cvar = var_query("container", "Container", 'label_values(container)', ds=LOKI, current="All")
svar = {"name": "search", "label": "Search", "type": "textbox", "query": "", "current": {"text": "", "value": ""}}
logs = [
    panel("timeseries", "Log volume", [q('sum by (container) (count_over_time({container=~"$container"} |~ "$search" [$__auto]))', "{{container}}", ds=LOKI)], 0, 0, 24, 7, ds=LOKI, decimals=0),
    panel("logs", "Logs", [q('{container=~"$container"} |~ "$search"', ds=LOKI)], 0, 7, 24, 22, ds=LOKI,
          opts={"showTime": True, "showLabels": True, "wrapLogMessage": True, "prettifyLogMessage": False, "sortOrder": "Descending", "dedupStrategy": "none", "enableLogDetails": True}),
]
json.dump(dashboard("logs", "Logs", logs, templating=[cvar, svar], tags=["logs"], rng="now-1h"), open(f"{OUT}/logs.json", "w"), indent=2)
# ── Claude Code (OTLP via Alloy) ─────────────────────────────────
TEMPO = {"type": "tempo", "uid": "tempo"}
pvar = var_query("provider", "Provider", 'label_values(claude_code_session_count_total, gen_ai_provider_name)', current="All")
hvar = var_query("host", "Host", 'label_values(claude_code_session_count_total{gen_ai_provider_name=~"$provider"}, host_name)', current="All")
CF = 'gen_ai_provider_name=~"$provider", host_name=~"$host"'
CE = f'{{service_name="claude-code", {CF}}}'
COST_NOTE = "Claude Code's own estimate at Anthropic list prices for the reported model name; a local model has no price, so its figure is not a cost"
cc = [
    row("Sessions", 0),
    panel("stat", "Sessions (range)", [q(f'sum(last_over_time(claude_code_session_count_total{{{CF}}}[$__range]) - min_over_time(claude_code_session_count_total{{{CF}}}[$__range])) or vector(0)')], 0, 1, 4, 4, decimals=0, opts={"graphMode": "none"}),
    panel("stat", "Active time (range)", [q(f'sum(last_over_time(claude_code_active_time_seconds_total{{{CF}}}[$__range]) - min_over_time(claude_code_active_time_seconds_total{{{CF}}}[$__range])) or vector(0)')], 4, 1, 4, 4, unit="s", decimals=0, opts={"graphMode": "none"}),
    panel("stat", "Tokens (range)", [q(f'sum(last_over_time(claude_code_token_usage_tokens_total{{{CF}}}[$__range]) - min_over_time(claude_code_token_usage_tokens_total{{{CF}}}[$__range])) or vector(0)')], 8, 1, 4, 4, unit="short", decimals=1, opts={"graphMode": "none"}),
    panel("stat", "Output tokens (range)", [q(f'sum(last_over_time(claude_code_token_usage_tokens_total{{{CF}, type="output"}}[$__range]) - min_over_time(claude_code_token_usage_tokens_total{{{CF}, type="output"}}[$__range])) or vector(0)')], 12, 1, 4, 4, unit="short", decimals=1, opts={"graphMode": "none"}),
    panel("stat", "Estimated cost (range)", [q(f'sum(last_over_time(claude_code_cost_usage_USD_total{{{CF}, gen_ai_provider_name="anthropic"}}[$__range]) - min_over_time(claude_code_cost_usage_USD_total{{{CF}, gen_ai_provider_name="anthropic"}}[$__range])) or vector(0)')], 16, 1, 4, 4, unit="currencyUSD", decimals=2, opts={"graphMode": "none"}, desc="Anthropic sessions only. " + COST_NOTE),
    panel("stat", "API errors (range)", [q(f'sum(count_over_time({CE} | event_name="api_error" [$__range])) or vector(0)', ds=LOKI)], 20, 1, 4, 4, ds=LOKI, decimals=0, thresholds=GYR(1, 5), opts={"graphMode": "none"}),
    panel("timeseries", "Sessions started by provider and host", [q(f'sum by (gen_ai_provider_name, host_name) (increase(claude_code_session_count_total{{{CF}}}[$__auto]))', "{{gen_ai_provider_name}} {{host_name}}")], 0, 5, 12, 8, decimals=0),
    panel("timeseries", "Active time by type", [q(f'sum by (type) (rate(claude_code_active_time_seconds_total{{{CF}}}[$__auto]))', "{{type}}")], 12, 5, 12, 8, unit="percentunit", desc="user: keyboard activity; cli: tool execution and model responses. Rate of active seconds per wall-clock second, summed over sessions"),

    row("Tokens and cost", 13),
    panel("timeseries", "Tokens per minute by type", [q(f'sum by (type) (rate(claude_code_token_usage_tokens_total{{{CF}}}[$__auto])) * 60', "{{type}}")], 0, 14, 8, 8, unit="short"),
    panel("timeseries", "Tokens per minute by model", [q(f'sum by (model) (rate(claude_code_token_usage_tokens_total{{{CF}}}[$__auto])) * 60', "{{model}}")], 8, 14, 8, 8, unit="short"),
    panel("timeseries", "Tokens per minute by provider", [q(f'sum by (gen_ai_provider_name) (rate(claude_code_token_usage_tokens_total{{{CF}}}[$__auto])) * 60', "{{gen_ai_provider_name}}")], 16, 14, 8, 8, unit="short"),
    panel("timeseries", "Cache hit ratio", [q(f'sum(rate(claude_code_token_usage_tokens_total{{{CF}, type="cacheRead"}}[$__auto])) / (sum(rate(claude_code_token_usage_tokens_total{{{CF}, type=~"cacheRead|input|cacheCreation"}}[$__auto])))', "cache read share")], 0, 22, 8, 8, unit="percentunit", min_=0, max_=1, desc="Cache-read tokens over all prompt tokens (input + cache read + cache creation)"),
    panel("timeseries", "Estimated cost per hour by model", [q(f'sum by (model) (rate(claude_code_cost_usage_USD_total{{{CF}, gen_ai_provider_name="anthropic"}}[$__auto])) * 3600', "{{model}}")], 8, 22, 8, 8, unit="currencyUSD", desc="Anthropic sessions only. " + COST_NOTE),
    panel("timeseries", "Tokens per minute by query source", [q(f'sum by (query_source) (rate(claude_code_token_usage_tokens_total{{{CF}}}[$__auto])) * 60', "{{query_source}}")], 16, 22, 8, 8, unit="short", desc="main: the conversation; subagent: Agent tool workers; auxiliary: background jobs such as compaction"),

    row("API requests (events)", 30),
    panel("timeseries", "API requests per minute by model", [q(f'sum by (model) (count_over_time({CE} | event_name="api_request" [$__auto])) * 60 / $__auto_ms * 1000 / 60', "{{model}}", ds=LOKI)], 0, 31, 8, 8, ds=LOKI, unit="reqpm"),
    panel("timeseries", "API request duration (p50 / p95)", [
        q(f'quantile_over_time(0.50, {CE} | event_name="api_request" | unwrap duration_ms [$__auto]) by ()', "p50", ds=LOKI),
        q(f'quantile_over_time(0.95, {CE} | event_name="api_request" | unwrap duration_ms [$__auto]) by ()', "p95", ds=LOKI, i=1),
    ], 8, 31, 8, 8, ds=LOKI, unit="ms"),
    panel("timeseries", "API errors per minute by status", [q(f'sum by (status_code) (count_over_time({CE} | event_name="api_error" [$__auto])) * 60 / $__auto_ms * 1000 / 60', "{{status_code}}", ds=LOKI)], 16, 31, 8, 8, ds=LOKI, unit="reqpm",
          overrides=[{"matcher": {"id": "byRegexp", "options": "5.."}, "properties": [{"id": "color", "value": {"mode": "fixed", "fixedColor": "red"}}]}]),

    row("Tools", 39),
    panel("timeseries", "Tool calls per minute by tool", [q(f'sum by (tool_name) (count_over_time({CE} | event_name="tool_result" [$__auto])) * 60 / $__auto_ms * 1000 / 60', "{{tool_name}}", ds=LOKI)], 0, 40, 8, 8, ds=LOKI, unit="reqpm"),
    panel("timeseries", "Tool duration p95 by tool", [q(f'quantile_over_time(0.95, {CE} | event_name="tool_result" | unwrap duration_ms [$__auto]) by (tool_name)', "{{tool_name}}", ds=LOKI)], 8, 40, 8, 8, ds=LOKI, unit="ms"),
    panel("timeseries", "Permission decisions per minute", [q(f'sum by (decision, source) (count_over_time({CE} | event_name="tool_decision" [$__auto])) * 60 / $__auto_ms * 1000 / 60', "{{decision}} {{source}}", ds=LOKI)], 16, 40, 8, 8, ds=LOKI, unit="reqpm",
          overrides=[{"matcher": {"id": "byRegexp", "options": "reject.*"}, "properties": [{"id": "color", "value": {"mode": "fixed", "fixedColor": "red"}}]}]),
    panel("table", "Tool failures (range)", [q(f'topk(20, sum by (tool_name, error_type) (count_over_time({CE} | event_name="tool_result" | success="false" [$__range])))', ds=LOKI, instant=True, format="table")], 0, 48, 12, 8, ds=LOKI,
          opts={"sortBy": [{"displayName": "Value", "desc": True}]}),
    panel("table", "Lines of code and commits (range)", [
        q(f'sum by (type) (last_over_time(claude_code_lines_of_code_count_total{{{CF}}}[$__range]) - min_over_time(claude_code_lines_of_code_count_total{{{CF}}}[$__range]))', "lines {{type}}", instant=True, format="table"),
        q(f'sum(last_over_time(claude_code_commit_count_total{{{CF}}}[$__range]) - min_over_time(claude_code_commit_count_total{{{CF}}}[$__range]))', "commits", instant=True, format="table", i=1),
        q(f'sum(last_over_time(claude_code_pull_request_count_total{{{CF}}}[$__range]) - min_over_time(claude_code_pull_request_count_total{{{CF}}}[$__range]))', "pull requests", instant=True, format="table", i=2),
    ], 12, 48, 12, 8),

    row("Prompts and traces", 56),
    panel("logs", "Prompts", [q(f'{CE} | event_name="user_prompt" | line_format "{{{{.prompt}}}}"', ds=LOKI)], 0, 57, 12, 12, ds=LOKI,
          opts={"showTime": True, "showLabels": False, "wrapLogMessage": True, "sortOrder": "Descending", "dedupStrategy": "none", "enableLogDetails": True},
          desc="Prompt text is exported only when OTEL_LOG_USER_PROMPTS=1 on the client; otherwise the line reads <REDACTED>"),
    {"id": next(_id), "type": "table", "title": "Recent interactions (Tempo)", "datasource": TEMPO, "gridPos": {"x": 12, "y": 57, "w": 12, "h": 12},
     "targets": [{"refId": "A", "datasource": TEMPO, "queryType": "traceql", "query": '{ resource.service.name="claude-code" && name="claude_code.interaction" }', "limit": 20, "tableType": "traces"}],
     "fieldConfig": {"defaults": {}, "overrides": []}, "options": {},
     "description": "One trace per prompt; spans for API calls, tool calls, hooks and permission waits. Needs CLAUDE_CODE_ENHANCED_TELEMETRY_BETA=1 on the client"},
    panel("logs", "Events", [q(f'{CE} | line_format "{{{{.event_name}}}} {{{{if .tool_name}}}}{{{{.tool_name}}}} {{{{end}}}}{{{{if .model}}}}{{{{.model}}}} {{{{end}}}}{{{{if .duration_ms}}}}{{{{.duration_ms}}}}ms{{{{end}}}}"', ds=LOKI)], 0, 69, 24, 10, ds=LOKI,
          opts={"showTime": True, "showLabels": False, "wrapLogMessage": False, "sortOrder": "Descending", "dedupStrategy": "none", "enableLogDetails": True}),
]
json.dump(dashboard("claude-code", "Claude Code", cc, templating=[pvar, hvar], tags=["claude-code"]), open(f"{OUT}/claude-code.json", "w"), indent=2)
print("dashboards written to", OUT)
