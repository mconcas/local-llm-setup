// Route Anthropic/OpenAI-style inference requests by their `model` field:
// names listed in SIDECAR_MODEL_NAMES go to SIDECAR_UPSTREAM (another
// instance of this stack, reached with a client certificate), names listed
// in LOCAL_MODEL_NAMES go to the local llama.cpp server, everything else to
// PASSTHROUGH_UPSTREAM. With no PASSTHROUGH_UPSTREAM configured every
// remaining request is served locally.
//
// `usage` is a response body filter that forwards every chunk untouched and
// records the token usage reported by the backend (Anthropic and OpenAI
// formats, streamed or not, plus llama.cpp timings) into log variables.

var USAGE_MAX_BUFFER = 4 * 1024 * 1024;

function names(envName) {
    return (process.env[envName] || '')
        .split(',')
        .map(function (s) { return s.trim(); })
        .filter(function (s) { return s.length > 0; });
}

function requestedModel(r) {
    var body = r.requestText;
    if (!body) {
        return '';
    }
    try {
        var model = JSON.parse(body).model;
        return typeof model === 'string' ? model : '';
    } catch (e) {
        return '';
    }
}

function hostOf(upstream) {
    return upstream.replace(/^[a-z]+:\/\//, '').replace(/[\/:].*$/, '');
}

function route(r) {
    var passthrough = process.env.PASSTHROUGH_UPSTREAM || '';
    var sidecar = process.env.SIDECAR_UPSTREAM || '';
    var model = requestedModel(r);
    r.variables.routed_model = model;
    if (sidecar !== '' && names('SIDECAR_MODEL_NAMES').indexOf(model) !== -1) {
        r.variables.route = 'sidecar';
        r.variables.sidecar_upstream = sidecar.replace(/\/+$/, '');
        r.variables.sidecar_host = hostOf(sidecar);
        r.variables.sidecar_ssl_name = process.env.SIDECAR_TLS_NAME || hostOf(sidecar);
        r.internalRedirect('@sidecar');
        return;
    }
    if (passthrough === '' || names('LOCAL_MODEL_NAMES').indexOf(model) !== -1) {
        r.variables.route = 'local';
        r.internalRedirect('@llama');
        return;
    }
    r.variables.route = 'passthrough';
    r.variables.passthrough_upstream = passthrough.replace(/\/+$/, '');
    r.variables.passthrough_host = hostOf(passthrough);
    r.internalRedirect('@passthrough');
}

function setNum(r, name, value) {
    if (typeof value === 'number' && isFinite(value)) {
        r.variables[name] = String(Math.round(value));
    }
}

function recordUsage(r, u) {
    if (!u || typeof u !== 'object') {
        return;
    }
    if (u.input_tokens !== undefined) {
        setNum(r, 'usage_input', u.input_tokens);
        setNum(r, 'usage_cache_read', u.cache_read_input_tokens);
        setNum(r, 'usage_cache_creation', u.cache_creation_input_tokens);
    }
    setNum(r, 'usage_output', u.output_tokens);
    if (u.prompt_tokens !== undefined) {
        setNum(r, 'usage_input', u.prompt_tokens);
        setNum(r, 'usage_output', u.completion_tokens);
        if (u.prompt_tokens_details) {
            setNum(r, 'usage_cache_read', u.prompt_tokens_details.cached_tokens);
        }
    }
}

function recordTimings(r, t) {
    if (!t || typeof t !== 'object') {
        return;
    }
    setNum(r, 'usage_prompt_ms', t.prompt_ms);
    setNum(r, 'usage_predicted_ms', t.predicted_ms);
}

function recordObject(r, obj) {
    if (!obj || typeof obj !== 'object') {
        return;
    }
    if (obj.type === 'message_start' && obj.message) {
        recordUsage(r, obj.message.usage);
        return;
    }
    recordUsage(r, obj.usage);
    recordTimings(r, obj.timings);
}

function recordText(r, text) {
    try {
        recordObject(r, JSON.parse(text));
    } catch (e) {
    }
}

function recordSseLines(r, text) {
    var lines = text.split('\n');
    for (var i = 0; i < lines.length; i++) {
        var line = lines[i];
        if (line.charCodeAt(line.length - 1) === 13) {
            line = line.slice(0, -1);
        }
        if (line.startsWith('data:') && line.indexOf('{') !== -1) {
            recordText(r, line.slice(5).trim());
        }
    }
}

function usage(r, data, flags) {
    r.sendBuffer(data, flags);
    var mode = r.variables.usage_mode;
    if (mode === '') {
        var ct = r.headersOut['Content-Type'] || '';
        if (r.headersOut['Content-Encoding']) {
            mode = 'skip';
        } else if (ct.indexOf('text/event-stream') !== -1) {
            mode = 'sse';
        } else if (ct.indexOf('application/json') !== -1) {
            mode = 'json';
        } else {
            mode = 'skip';
        }
        r.variables.usage_mode = mode;
    }
    if (mode === 'skip') {
        return;
    }
    var buf = r.variables.usage_buf + data;
    if (mode === 'json') {
        if (buf.length > USAGE_MAX_BUFFER) {
            r.variables.usage_mode = 'skip';
            r.variables.usage_buf = '';
            return;
        }
        if (flags.last) {
            recordText(r, buf);
            r.variables.usage_buf = '';
        } else {
            r.variables.usage_buf = buf;
        }
        return;
    }
    var cut = buf.lastIndexOf('\n');
    if (flags.last) {
        recordSseLines(r, buf);
        r.variables.usage_buf = '';
    } else if (cut === -1) {
        r.variables.usage_buf = buf.length > USAGE_MAX_BUFFER ? '' : buf;
    } else {
        recordSseLines(r, buf.slice(0, cut));
        r.variables.usage_buf = buf.slice(cut + 1);
    }
}

export default { route, usage };
