// Route Anthropic/OpenAI-style inference requests by their `model` field:
// names listed in LOCAL_MODEL_NAMES (comma-separated) go to the local
// llama.cpp server, everything else to PASSTHROUGH_UPSTREAM. With no
// PASSTHROUGH_UPSTREAM configured every request is served locally.

function localModels() {
    return (process.env.LOCAL_MODEL_NAMES || '')
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

function route(r) {
    var upstream = process.env.PASSTHROUGH_UPSTREAM || '';
    var model = requestedModel(r);
    r.variables.routed_model = model;
    if (upstream === '' || localModels().indexOf(model) !== -1) {
        r.variables.route = 'local';
        r.internalRedirect('@llama');
        return;
    }
    r.variables.route = 'passthrough';
    r.variables.passthrough_upstream = upstream.replace(/\/+$/, '');
    r.variables.passthrough_host = upstream.replace(/^[a-z]+:\/\//, '').replace(/[\/:].*$/, '');
    r.internalRedirect('@passthrough');
}

export default { route };
