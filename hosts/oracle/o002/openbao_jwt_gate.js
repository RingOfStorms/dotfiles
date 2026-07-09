// openbao_jwt_gate.js — njs access gate for the public OpenBao bootstrap edge.
//
// Runs on o002 (the public gateway) in FRONT of OpenBao's own Zitadel-JWT auth.
// A request may only *reach* OpenBao's login / KV endpoints from the public
// internet if it presents a valid, unexpired, correctly-issued+audienced
// Zitadel JWT (RS256, signature verified against Zitadel's JWKS). This is
// defense-in-depth network-layer pre-auth — it does NOT replace OpenBao's auth.
//
// Why it's shaped this way (validated end-to-end against real nginx+njs):
//   - vault-agent's auto_auth POSTs {"role":..,"jwt":".."} to the login
//     endpoint — the JWT is in the BODY, not an Authorization header. So we run
//     as a js_content handler, read the body, and pull out `.jwt`. For KV GETs
//     (no body) and for curl / onboarding scripts we also accept
//     `Authorization: Bearer <jwt>`. Either way it's the SAME Zitadel machine
//     token the box already has — no second secret to transfer.
//   - RS256 verify via crypto.subtle against Zitadel's JWKS, cached in a shared
//     dict (js_shared_dict_zone) so we don't refetch per request.
//   - On success we internalRedirect to @openbao_upstream (preserves method +
//     body). On ANY failure we 401 and OpenBao is never contacted.
//
// Required nginx wiring (see hosts/oracle/o002/nginx.nix):
//   js_shared_dict_zone zone=openbao_jwks:64k timeout=3600s;
//   js_import openbao_gate from <this file>;
//   resolver <ip>;                       # ngx.fetch needs a resolver
//   js_fetch_trusted_certificate <ca>;   # to verify the HTTPS JWKS endpoint
//   js_var $jwks_uri ...; $jwt_issuer ...; $jwt_audience ...;
//   internal location @openbao_upstream { proxy_pass http://UPSTREAM; }

function b64urlToBuf(s) {
    s = s.replace(/-/g, '+').replace(/_/g, '/');
    while (s.length % 4) s += '=';
    return Buffer.from(s, 'base64');
}

function decodeSegment(seg) {
    return JSON.parse(b64urlToBuf(seg).toString('utf8'));
}

// Fetch (and cache) the JWKS from Zitadel; return the JWK matching `kid`.
// `allowRefetch` guards a single cache-busting retry when the kid is missing
// (key rotation) so we can't loop forever.
async function getJwk(r, kid, allowRefetch) {
    const dict = ngx.shared && ngx.shared.openbao_jwks;
    let jwksText = dict ? dict.get('jwks') : undefined;

    if (!jwksText) {
        const uri = r.variables.jwks_uri;
        // Optional Host header override: lets us fetch the JWKS from h001
        // directly over the tailnet (http://<overlay-ip>/... with
        // Host: sso.joshuabell.xyz) instead of the public name, which would
        // hairpin through Oracle's NAT (documented-broken) back to o002.
        const host = r.variables.jwks_host;
        const opts = { method: 'GET' };
        if (host) {
            opts.headers = { Host: host };
        }
        r.log('openbao-gate: fetching JWKS from ' + uri + (host ? ' (Host: ' + host + ')' : ''));
        const resp = await ngx.fetch(uri, opts);
        if (resp.status !== 200) {
            throw new Error('JWKS fetch HTTP ' + resp.status);
        }
        jwksText = await resp.text();
        if (dict) {
            dict.set('jwks', jwksText);
        }
    }

    const keys = (JSON.parse(jwksText).keys) || [];
    for (let i = 0; i < keys.length; i++) {
        if (keys[i].kid === kid) return keys[i];
    }

    // kid not found — cache may predate a Zitadel key rotation. Bust once.
    if (allowRefetch && dict) {
        dict.delete('jwks');
        return getJwk(r, kid, false);
    }
    throw new Error('no JWK for kid ' + kid);
}

async function verifyJwt(r, token) {
    const parts = token.split('.');
    if (parts.length !== 3) throw new Error('malformed JWT');

    const header = decodeSegment(parts[0]);
    if (header.alg !== 'RS256') throw new Error('unexpected alg ' + header.alg);

    // Verify the signature BEFORE trusting any claim.
    const jwk = await getJwk(r, header.kid, true);
    const key = await crypto.subtle.importKey(
        'jwk',
        { kty: jwk.kty, n: jwk.n, e: jwk.e, alg: 'RS256', ext: true },
        { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' },
        false,
        ['verify']
    );
    const ok = await crypto.subtle.verify(
        { name: 'RSASSA-PKCS1-v1_5' },
        key,
        b64urlToBuf(parts[2]),
        Buffer.from(parts[0] + '.' + parts[1])
    );
    if (!ok) throw new Error('bad signature');

    // Claims (only after signature verified).
    const payload = decodeSegment(parts[1]);
    const now = Math.floor(Date.now() / 1000);

    if (typeof payload.exp !== 'number' || payload.exp <= now) {
        throw new Error('expired');
    }
    if (payload.nbf && payload.nbf > now + 60) {
        throw new Error('not yet valid');
    }

    const expectIss = r.variables.jwt_issuer;
    if (expectIss && payload.iss !== expectIss) {
        throw new Error('bad issuer ' + payload.iss);
    }

    const expectAud = r.variables.jwt_audience;
    if (expectAud) {
        const aud = payload.aud;
        const audOk = Array.isArray(aud) ? aud.indexOf(expectAud) !== -1
                                         : aud === expectAud;
        if (!audOk) throw new Error('bad audience');
    }

    return payload;
}

function extractToken(r) {
    // Prefer Authorization: Bearer (KV GETs, curl, onboarding scripts).
    const auth = r.headersIn['Authorization'];
    if (auth) {
        const m = auth.match(/^Bearer\s+(.+)$/i);
        if (m) return m[1];
    }
    // Fall back to the login POST/PUT body: {"role":..,"jwt":".."}.
    const body = r.requestText;
    if (body) {
        try {
            const j = JSON.parse(body);
            if (j && typeof j.jwt === 'string') return j.jwt;
        } catch (e) { /* not JSON — ignore */ }
    }
    return null;
}

// js_content handler: validate, then proxy to OpenBao or 401.
async function gate(r) {
    try {
        const token = extractToken(r);
        if (!token) {
            r.return(401, '{"errors":["openbao-gate: no Zitadel JWT presented"]}\n');
            return;
        }
        await verifyJwt(r, token);
        r.log('openbao-gate: JWT OK -> OpenBao');
        r.internalRedirect('@openbao_upstream');
    } catch (e) {
        r.error('openbao-gate: reject: ' + e.message);
        r.return(401, '{"errors":["openbao-gate: invalid Zitadel JWT"]}\n');
    }
}

export default { gate, verifyJwt };
