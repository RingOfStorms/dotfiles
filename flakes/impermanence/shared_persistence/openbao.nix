# OpenBao runtime socket dir + persisted secret blobs that
# secrets-bao writes out for other services to consume.
{
  system = {
    directories = [
      "/run/openbao"
      "/var/lib/openbao-secrets"
    ];
    files = [ ];
  };
  user = {
    directories = [ ];
    files = [ ];
  };
}
