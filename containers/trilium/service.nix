# Trilium notes (notes.joshuabell.xyz) together with the oauth2-proxy that
# guards it. Trilium runs with noAuthentication = true, so the two must never
# be split: the only ways in are the auth_request-protected vhost and the
# tailnet-only overlay vhost on 100.64.0.13:9112 (for the desktop app).
# Was hosts/h001/mods/{trilium,oauth2-proxy}.nix on bare metal.
{
  name = "trilium";
  kind = "nixos";
  description = "Trilium notes + oauth2-proxy (notes / sso-proxy.joshuabell.xyz)";
  host = "h001";

  persist = {
    data = "/var/lib/trilium"; # document.db (+wal), backups, session secret
    nixos = "/var/lib/nixos";
  };

  # Stopped copies of document.db + its WAL are consistent; no hook needed.

  nginx = ''
    # oauth2-proxy itself: login start/callback for every *.joshuabell.xyz
    # site that uses auth_request (cookie-domain .joshuabell.xyz).
    server {
      listen 80;
      listen [::]:80;
      listen 443 ssl;
      listen [::]:443 ssl;
      server_name sso-proxy.joshuabell.xyz;
      ssl_certificate /var/lib/acme/joshuabell.xyz/fullchain.pem;
      ssl_certificate_key /var/lib/acme/joshuabell.xyz/key.pem;
      location / {
        proxy_pass http://127.0.0.1:4180;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $connection_upgrade;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Host $host;
        proxy_set_header X-Forwarded-Proto https;
      }
      location /oauth2/ {
        proxy_pass http://127.0.0.1:4180;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Forwarded-Host $host;
        proxy_set_header X-Scheme $scheme;
        proxy_set_header X-Auth-Request-Redirect $scheme://$host$request_uri;
      }
    }

    # Trilium behind oauth2-proxy; only members of the `notes` group.
    server {
      listen 80;
      listen [::]:80;
      listen 443 ssl;
      listen [::]:443 ssl;
      server_name notes.joshuabell.xyz;
      ssl_certificate /var/lib/acme/joshuabell.xyz/fullchain.pem;
      ssl_certificate_key /var/lib/acme/joshuabell.xyz/key.pem;
      client_max_body_size 0; # TRILIUM_NO_UPLOAD_LIMIT

      auth_request /oauth2/auth;
      error_page 401 = @redirectToAuth2ProxyLogin;

      location = /oauth2/auth {
        auth_request off;
        proxy_pass http://127.0.0.1:4180/oauth2/auth?allowed_groups=notes;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Forwarded-Host $host;
        proxy_set_header X-Scheme $scheme;
        proxy_set_header Content-Length "";
        proxy_pass_request_body off;
      }
      location @redirectToAuth2ProxyLogin {
        auth_request off;
        return 307 https://sso-proxy.joshuabell.xyz/oauth2/start?rd=$scheme://$host$request_uri;
      }
      location / {
        proxy_pass http://127.0.0.1:9111;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $connection_upgrade;
        auth_request_set $user $upstream_http_x_auth_request_user;
        auth_request_set $email $upstream_http_x_auth_request_email;
        auth_request_set $auth_cookie $upstream_http_set_cookie;
        proxy_set_header X-User $user;
        proxy_set_header X-Email $email;
        add_header Set-Cookie $auth_cookie;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Forwarded-Host $host;
      }
    }

    # Tailnet-only, unauthenticated: for the Trilium desktop app, which
    # can't do the OAuth flow. Bound to h001's overlay IP only.
    server {
      listen @OVERLAY_IP@:9112;
      server_name h001.net.joshuabell.xyz;
      client_max_body_size 0;
      location / {
        proxy_pass http://127.0.0.1:9111;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $connection_upgrade;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Forwarded-Host $host;
      }
    }
  '';
}
