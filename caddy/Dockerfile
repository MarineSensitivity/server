# pinned: `caddy:latest` moved under us once (an old cached builder produced a
# Caddy without directives the routes file uses). Bump both tags together.
FROM caddy:2.11.4-builder AS builder
# pmtiles_proxy (file.marinesensitivity.org tiles) + jwtauth: the origin-side
# check for the signed-in preview host. Cloudflare Access sets a
# Cf-Access-Jwt-Assertion header on every request it lets through; jwtauth
# verifies it against the team's JWKS + the application AUD, so a request that
# reaches this box WITHOUT going through Access (origin IP, another hostname)
# gets a 401 instead of the app. Pinned: the directive vocabulary the Caddyfile
# uses (jwk_url, from_header, from_cookies, issuer/audience_whitelist,
# user_claims) is the v1.x contract.
RUN xcaddy build \
  --with github.com/protomaps/go-pmtiles/caddy \
  --with github.com/ggicci/caddy-jwt@v1.3.0

FROM caddy:2.11.4
COPY --from=builder /usr/bin/caddy /usr/bin/caddy
