docker run \
 -e hostname=https://obsidiansync.joshuabell.xyz \
 -e database=obsidian_sync \
 -e username=obsidian_admin \
 -e password=$REPLACE \
 docker.io/oleduc/docker-obsidian-livesync-couchdb:master \
 deno -A /scripts/generate_setupuri.ts
