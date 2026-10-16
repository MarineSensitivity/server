#!/usr/bin/env python3
"""The redirect MATRIX of the Atlas cutover (B2), driven by atlas_cutover_local.sh.

usage: atlas_cutover_matrix.py <app_port> <preview_port> <basic-auth user:password> <shiny_ms_port> <shiny_om_port>

Two local caddys are running: the REAL app.marinesensitivity.org vhost (public,
PREVIEW_RESTRICTED_VERSIONS=v7b|v7c|v8|v9) and the REAL preview_routes.caddy behind a
basic_auth stand-in for jwtauth. Each case sends one raw request (http.client sends the
path byte for byte, so percent-encoding is NOT normalized) and asserts

  * the status and the Location of the FIRST hop, exactly,
  * where the chain ENDS, following redirects across the two hosts the way a browser
    would (app.* -> the public server, preview.* -> the preview server with the
    reviewer's credentials, marinesensitivity.org/atlas/ = GitHub Pages = the end),
  * the number of redirects taken, which must be <= 2 (and is asserted exactly).

Locations are compared as emitted: absolute for the public host, relative for the
preview host.  Prints one line per case and exits non-zero on any failure.
"""
import base64
import http.client
import sys
import urllib.parse

pub_port, prev_port, creds = int(sys.argv[1]), int(sys.argv[2]), sys.argv[3]
shiny_ms_port, shiny_om_port = int(sys.argv[4]), int(sys.argv[5])
AUTH = "Basic " + base64.b64encode(creds.encode()).decode()

PAGES = "https://marinesensitivity.org/atlas/"          # GitHub Pages: the end of a public chain
PREV = "https://preview.marinesensitivity.org"
FIXTURE_200 = "HTTP 200"                                 # the preview Atlas fixture index

HOSTS = {  # host -> (port, send credentials)
    "app.marinesensitivity.org": (pub_port, False),
    "preview.marinesensitivity.org": (prev_port, True),
    # the same public Shiny Server is also proxied by these two vhosts (scores/species were
    # reachable there too); the SAME matrix must hold on them
    "shiny.marinesensitivity.org": (shiny_ms_port, False),
    "shiny.oceanmetrics.io": (shiny_om_port, False),
}


def fetch(host, target, auth):
    port, _ = HOSTS[host]
    c = http.client.HTTPConnection("127.0.0.1", port, timeout=15)
    c.putrequest("GET", target, skip_host=True, skip_accept_encoding=True)
    c.putheader("Host", host)
    if auth:
        c.putheader("Authorization", AUTH)
    c.endheaders()
    r = c.getresponse()
    r.read()
    out = (r.status, r.getheader("Location"), dict((k.lower(), v) for k, v in r.getheaders()))
    c.close()
    return out


def chain(host, target, auth):
    """-> (first_status, first_location, hops, end, headers_of_first)"""
    first = None
    hops = 0
    cur_host, cur_target = host, target
    for _ in range(6):
        status, loc, hdr = fetch(cur_host, cur_target, auth and HOSTS[cur_host][1])
        if first is None:
            first = (status, loc, hdr)
        if status not in (301, 302, 303, 307, 308) or loc is None:
            return first[0], first[1], hops, "HTTP %d" % status, first[2]
        hops += 1
        u = urllib.parse.urlsplit(loc)
        if u.netloc == "marinesensitivity.org":
            return first[0], first[1], hops, loc, first[2]       # GitHub Pages: the end
        if u.netloc and u.netloc not in HOSTS:
            return first[0], first[1], hops, loc, first[2]       # left our hosts
        if u.netloc:                                             # absolute: keep the RAW path+query
            cur_host, cur_target = u.netloc, loc.split(u.netloc, 1)[1]
        else:                                                    # relative: same host
            cur_target = loc
    return first[0], first[1], hops, "LOOP", first[2]


TAGS = {"app.marinesensitivity.org": "app ", "shiny.marinesensitivity.org": "shms", "shiny.oceanmetrics.io": "shom"}
fails = 0
n = 0


def case(label, host, target, status, location, end, hops, auth=True):
    """status/location: the FIRST hop; end: final URL or 'HTTP nnn'; hops: redirects taken."""
    global fails, n
    n += 1
    s, loc, h, e, hdr = chain(host, target, auth)
    problems = []
    if s != status:
        problems.append("status %s != %s" % (s, status))
    if loc != location:
        problems.append("Location %r != %r" % (loc, location))
    if end is not None and e != end:
        problems.append("end %r != %r" % (e, end))
    if hops is not None and h != hops:
        problems.append("hops %d != %d" % (h, hops))
    if h > 2:
        problems.append("hops %d > 2" % h)
    if "set-cookie" in hdr:
        problems.append("Set-Cookie in the redirect (header injection?)")
    tag = TAGS.get(host, "prev")
    if problems:
        fails += 1
        print("  FAIL %s %-52s %s" % (tag, target, "; ".join(problems)))
    else:
        print("  ok   %s %-52s %s %s (%d hop%s)" % (tag, target, s, (loc or "-"), h, "" if h == 1 else "s"))


def not_redirected(label, host, target, auth=True):
    global fails, n
    n += 1
    s, loc, h, e, hdr = chain(host, target, auth)
    tag = TAGS.get(host, "prev")
    if s in (301, 302, 303, 307, 308) or loc:
        fails += 1
        print("  FAIL %s %-52s redirected: %s %s" % (tag, target, s, loc))
    else:
        print("  ok   %s %-52s not redirected (%s)" % (tag, target, s))


P = "preview.marinesensitivity.org"
K = "am%7CFis-29291"            # a percent-encoded mdl_key, as published links carry it

def public_matrix(A):
    print("== %s: path-form versions (public releases) ==" % A)
    for v in ("v7", "v6", "v1"):
        case("scores", A, "/%s/scores/" % v, 301, PAGES + "?ver=" + v, PAGES + "?ver=" + v, 1)
    case("scores noslash", A, "/v7/scores", 301, PAGES + "?ver=v7", PAGES + "?ver=v7", 1)
    case("scores subpath", A, "/v7/scores/x/y", 301, PAGES + "?ver=v7", PAGES + "?ver=v7", 1)
    case("scores empty ?", A, "/v7/scores/?", 301, PAGES + "?ver=v7", PAGES + "?ver=v7", 1)
    case("scores query", A, "/v7/scores/?a=1&b=2", 301, PAGES + "?ver=v7&a=1&b=2", PAGES + "?ver=v7&a=1&b=2", 1)
    case("scores splash", A, "/v7/scores/?splash=false", 301, PAGES + "?ver=v7&splash=false", PAGES + "?ver=v7&splash=false", 1)
    case("species", A, "/v7/species/", 301, PAGES + "?ver=v7&lens=species", PAGES + "?ver=v7&lens=species", 1)
    case("species noslash", A, "/v7/species", 301, PAGES + "?ver=v7&lens=species", PAGES + "?ver=v7&lens=species", 1)
    case("species mdl_key", A, "/v7/species/?mdl_key=" + K, 301, PAGES + "?ver=v7&lens=species&mdl_key=" + K, PAGES + "?ver=v7&lens=species&mdl_key=" + K, 1)
    case("species mdl_seq", A, "/v6/species/?mdl_seq=1434", 301, PAGES + "?ver=v6&lens=species&mdl_seq=1434", PAGES + "?ver=v6&lens=species&mdl_seq=1434", 1)
    case("species splash+seq", A, "/v7/species/?mdl_seq=1434&splash=false", 301, PAGES + "?ver=v7&lens=species&mdl_seq=1434&splash=false", PAGES + "?ver=v7&lens=species&mdl_seq=1434&splash=false", 1)
    case("species ?ver= in Q (path wins, Q verbatim)", A, "/v7/species/?ver=v7&mdl_seq=5", 301, PAGES + "?ver=v7&lens=species&ver=v7&mdl_seq=5", None, 1)
    case("species crlf-encoded", A, "/v7/species/?x=%0d%0aSet-Cookie:a=b", 301, PAGES + "?ver=v7&lens=species&x=%0d%0aSet-Cookie:a=b", None, 1)
    case("atlas path, public version", A, "/v7/atlas/", 301, PAGES + "?ver=v7", PAGES + "?ver=v7", 1)
    case("atlas path, public version, query", A, "/v7/atlas/?lens=species&sp=1", 301, PAGES + "?ver=v7&lens=species&sp=1", None, 1)

    print("== %s: RESTRICTED versions go straight to the preview Atlas (one hop) ==" % A)
    for v in ("v7b", "v7c", "v8", "v9"):
        case("scores", A, "/%s/scores/" % v, 302, "%s/%s/atlas/" % (PREV, v), FIXTURE_200, 1)
        case("species", A, "/%s/species/?mdl_key=%s" % (v, K), 302, "%s/%s/atlas/?lens=species&mdl_key=%s" % (PREV, v, K), FIXTURE_200, 1)
    case("restricted scores query", A, "/v9/scores/?splash=false&a=1", 302, PREV + "/v9/atlas/?splash=false&a=1", FIXTURE_200, 1)
    case("restricted species, no query", A, "/v8/species/", 302, PREV + "/v8/atlas/?lens=species", FIXTURE_200, 1)
    case("restricted species noslash", A, "/v8/species", 302, PREV + "/v8/atlas/?lens=species", FIXTURE_200, 1)
    case("restricted species mdl_seq", A, "/v7b/species/?mdl_seq=77", 302, PREV + "/v7b/atlas/?lens=species&mdl_seq=77", FIXTURE_200, 1)
    case("restricted atlas path", A, "/v9/atlas/?lens=species&sp=1", 302, PREV + "/v9/atlas/?lens=species&sp=1", FIXTURE_200, 1)
    case("restricted atlas path, noslash", A, "/v9/atlas", 302, PREV + "/v9/atlas", FIXTURE_200, 2)

    print("== %s: unversioned /scores/ and /species/ ==" % A)
    case("scores", A, "/scores/", 301, PAGES, PAGES, 1)
    case("scores noslash", A, "/scores", 301, PAGES, PAGES, 1)
    case("scores empty ?", A, "/scores/?", 301, PAGES, PAGES, 1)
    case("scores ?ver=", A, "/scores/?ver=v7", 301, PAGES + "?ver=v7", PAGES + "?ver=v7", 1)
    case("scores splash", A, "/scores/?splash=false", 301, PAGES + "?splash=false", PAGES + "?splash=false", 1)
    case("species", A, "/species/", 301, PAGES + "?lens=species", PAGES + "?lens=species", 1)
    case("species noslash ?ver=", A, "/species?ver=v6", 301, PAGES + "?lens=species&ver=v6", PAGES + "?lens=species&ver=v6", 1)
    case("species ver+mdl_key", A, "/species/?ver=v7&mdl_key=" + K, 301, PAGES + "?lens=species&ver=v7&mdl_key=" + K, PAGES + "?lens=species&ver=v7&mdl_key=" + K, 1)
    case("species mdl_seq only", A, "/species/?mdl_seq=1434", 301, PAGES + "?lens=species&mdl_seq=1434", PAGES + "?lens=species&mdl_seq=1434", 1)
    case("species restricted ver= -> preview", A, "/species/?ver=v8&mdl_key=abc", 302, PREV + "/v8/atlas/?lens=species&ver=v8&mdl_key=abc", FIXTURE_200, 1)
    case("scores restricted ver= -> preview", A, "/scores/?ver=v9", 302, PREV + "/v9/atlas/?ver=v9", FIXTURE_200, 1)
    case("scores restricted ver= noslash", A, "/scores?ver=v7c&x=1", 302, PREV + "/v7c/atlas/?ver=v7c&x=1", FIXTURE_200, 1)
    case("species junk ver= stays on the public Atlas", A, "/species/?ver=//evil.com", 301, PAGES + "?lens=species&ver=//evil.com", None, 1)
    case("scores ver=v8x is not restricted", A, "/scores/?ver=v8x", 301, PAGES + "?ver=v8x", None, 1)

    print("== %s: the retired aliases, one hop ==" % A)
    case("/mapgl/", A, "/mapgl/", 301, PAGES + "?ver=v7", PAGES + "?ver=v7", 1)
    case("/mapgl", A, "/mapgl", 301, PAGES + "?ver=v7", PAGES + "?ver=v7", 1)
    case("/mapsp/?mdl_seq", A, "/mapsp/?mdl_seq=1434", 301, PAGES + "?ver=v7&lens=species&mdl_seq=1434", PAGES + "?ver=v7&lens=species&mdl_seq=1434", 1)
    case("/mapsp/ no query", A, "/mapsp/", 301, PAGES + "?ver=v7&lens=species", PAGES + "?ver=v7&lens=species", 1)
    case("/mapsp/?mdl_key", A, "/mapsp/?mdl_key=" + K, 301, PAGES + "?ver=v7&lens=species&mdl_key=" + K, None, 1)
    case("/mapgl_v3/", A, "/mapgl_v3/", 301, PAGES + "?ver=v3", PAGES + "?ver=v3", 1)
    case("/mapgl_v3b/x?q", A, "/mapgl_v3b/x?q=1", 301, PAGES + "?ver=v3b&q=1", None, 1)
    case("/mapsp_v4/?mdl_seq", A, "/mapsp_v4/?mdl_seq=9", 301, PAGES + "?ver=v4&lens=species&mdl_seq=9", PAGES + "?ver=v4&lens=species&mdl_seq=9", 1)
    case("/mapsp_v1", A, "/mapsp_v1", 301, PAGES + "?ver=v1&lens=species", PAGES + "?ver=v1&lens=species", 1)
    case("/scores_v6/", A, "/scores_v6/", 301, PAGES + "?ver=v6", PAGES + "?ver=v6", 1)
    case("/species_v6/?mdl_seq", A, "/species_v6/?mdl_seq=5", 301, PAGES + "?ver=v6&lens=species&mdl_seq=5", PAGES + "?ver=v6&lens=species&mdl_seq=5", 1)
    case("/scores_v8/ (restricted)", A, "/scores_v8/", 302, PREV + "/v8/atlas/", FIXTURE_200, 1)
    case("/species_v8/?ver=&mdl_key (restricted)", A, "/species_v8/?ver=v8&mdl_key=abc", 302, PREV + "/v8/atlas/?lens=species&ver=v8&mdl_key=abc", FIXTURE_200, 1)
    case("/species_v9/?mdl_key (restricted)", A, "/species_v9/?mdl_key=" + K, 302, PREV + "/v9/atlas/?lens=species&mdl_key=" + K, FIXTURE_200, 1)
    case("/scores_v7/ (public, not v8)", A, "/scores_v7/", 301, PAGES + "?ver=v7", PAGES + "?ver=v7", 1)

    print("== %s: things that must NOT be redirected ==" % A)
    for t in ("/scoresx/", "/speciesx/", "/mapglx", "/mapspx/", "/v7/scoresx/", "/v7/other/", "/vX/scores/", "/V7/scores/", "/scores_x/", "/", "/something"):
        not_redirected("other", A, t)



for A in ("app.marinesensitivity.org", "shiny.marinesensitivity.org", "shiny.oceanmetrics.io"):
    public_matrix(A)

print("== preview host: version in the path (authenticated) ==")
case("scores", P, "/v8/scores/", 301, "/v8/atlas/", FIXTURE_200, 1)
case("scores noslash", P, "/v8/scores", 301, "/v8/atlas/", FIXTURE_200, 1)
case("scores subpath", P, "/v8/scores/x/y", 301, "/v8/atlas/", FIXTURE_200, 1)
case("scores empty ?", P, "/v8/scores/?", 301, "/v8/atlas/", FIXTURE_200, 1)
case("scores mdl_key", P, "/v9/scores/?mdl_key=" + K, 301, "/v9/atlas/?mdl_key=" + K, FIXTURE_200, 1)
case("scores splash", P, "/v7c/scores/?splash=false&a=1", 301, "/v7c/atlas/?splash=false&a=1", FIXTURE_200, 1)
case("species", P, "/v8/species/", 301, "/v8/atlas/?lens=species", FIXTURE_200, 1)
case("species noslash", P, "/v8/species", 301, "/v8/atlas/?lens=species", FIXTURE_200, 1)
case("species mdl_key", P, "/v9/species/?mdl_key=" + K, 301, "/v9/atlas/?lens=species&mdl_key=" + K, FIXTURE_200, 1)
case("species mdl_seq", P, "/v7b/species/?mdl_seq=1434&splash=false", 301, "/v7b/atlas/?lens=species&mdl_seq=1434&splash=false", FIXTURE_200, 1)
case("species ?ver= in Q is carried, inert", P, "/v9/species/?ver=v8&mdl_seq=1", 301, "/v9/atlas/?lens=species&ver=v8&mdl_seq=1", None, 1)

print("== preview host: the pre-path ?ver= spelling ==")
case("scores ?ver=", P, "/scores/?ver=v8", 301, "/v8/atlas/?ver=v8", FIXTURE_200, 1)
case("scores ?ver= + mdl_key", P, "/scores/?ver=v9&mdl_key=" + K, 301, "/v9/atlas/?ver=v9&mdl_key=" + K, FIXTURE_200, 1)
case("scores noslash ?ver=", P, "/scores?ver=v7b", 301, "/v7b/atlas/?ver=v7b", FIXTURE_200, 1)
case("species ?ver=", P, "/species/?ver=v9", 301, "/v9/atlas/?lens=species&ver=v9", FIXTURE_200, 1)
case("species ?ver= + mdl_seq", P, "/species/?ver=v7c&mdl_seq=3", 301, "/v7c/atlas/?lens=species&ver=v7c&mdl_seq=3", FIXTURE_200, 1)
case("species noslash ?ver=", P, "/species?ver=v9&mdl_key=" + K, 301, "/v9/atlas/?lens=species&ver=v9&mdl_key=" + K, FIXTURE_200, 1)
case("no ver -> landing (never proxied)", P, "/scores/", 302, "/", None, 1)
case("species no ver -> landing", P, "/species/?mdl_seq=1", 302, "/", None, 1)
case("junk ver -> landing, no redirect to it", P, "/scores/?ver=junk", 302, "/", None, 1)
case("path-injection ver -> landing", P, "/scores/?ver=//evil.com", 302, "/", None, 1)
case("path-injection ver 2 -> landing", P, "/species/?ver=/../evil", 302, "/", None, 1)

print("== preview host: pre-existing atlas routes still resolve ==")
case("atlas ?ver= -> path (existing)", P, "/atlas/?ver=v9", 301, "/v9/atlas/", FIXTURE_200, 1)
case("atlas noslash (existing 308)", P, "/v9/atlas?lens=species", 308, "/v9/atlas/?lens=species", FIXTURE_200, 1)
case("atlas served", P, "/v9/atlas/?lens=species", 200, None, FIXTURE_200, 0)

print("== preview host: NO redirect answers before authentication ==")
for t in ("/v8/scores/", "/v8/scores", "/v9/species/?mdl_key=" + K, "/scores/?ver=v8", "/species/?ver=v9&mdl_seq=1",
          "/scores/", "/species/", "/v9/atlas", "/atlas/?ver=v9", "/v8/scores/?x=1"):
    n += 1
    s, loc, h, e, hdr = chain(P, t, False)
    if s == 401 and not loc:
        print("  ok   prev %-52s unauthenticated -> 401, no Location" % t)
    else:
        fails += 1
        print("  FAIL prev %-52s unauthenticated -> %s Location=%r (a redirect answered before auth)" % (t, s, loc))

print("%d cases, %d failed" % (n, fails))
sys.exit(1 if fails else 0)
