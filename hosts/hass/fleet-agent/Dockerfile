FROM alpine:3.21

RUN apk add --no-cache jq smartmontools

COPY bin/fleet /usr/local/bin/fleet
COPY run.sh /run.sh
RUN chmod +x /usr/local/bin/fleet /run.sh

CMD ["/run.sh"]
