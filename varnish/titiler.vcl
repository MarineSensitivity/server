vcl 4.1;

import std;

backend default {
  .host                  = "titiler";
  .port                  = "8000";
  .connect_timeout       = 5s;
  .first_byte_timeout    = 60s;
  .between_bytes_timeout = 10s;
}

sub vcl_recv {
  # only GET / HEAD are cacheable
  if (req.method != "GET" && req.method != "HEAD") {
    return (pass);
  }

  # titiler is stateless — drop auth/session noise so it can't vary the cache
  unset req.http.Cookie;
  unset req.http.Authorization;

  # canonicalize query param order so semantically-identical URLs share a key
  set req.url = std.querysort(req.url);

  return (hash);
}

sub vcl_backend_response {
  # never carry session cookies into cache
  unset beresp.http.Set-Cookie;

  # long TTL on msens tile / metadata routes
  if (bereq.url ~ "^/msens/(tiles/|tilejson|bounds|statistics)") {
    set beresp.ttl   = 7d;
    set beresp.grace = 1h;    # serve stale during backend slowness
    set beresp.keep  = 24h;   # retain for conditional refresh
  }

  # brief TTL on 4xx/5xx to prevent stampede but allow fast recovery
  if (beresp.status >= 400) {
    set beresp.ttl   = 60s;
    set beresp.grace = 0s;
  }
}

sub vcl_deliver {
  if (obj.hits > 0) {
    set resp.http.X-Cache = "HIT";
  } else {
    set resp.http.X-Cache = "MISS";
  }
  set resp.http.X-Cache-Hits = obj.hits;
}
