# Pure BusyBox Alpine SSH test server (dev@localhost:2223).
# Only openssh-server is added, so df, grep, head, cat, uname, hostname and
# sh are all BusyBox applets: this is the BusyBox compatibility target for
# Scripts/remote/*.sh. Do not add coreutils, grep, procps or bash here.
FROM alpine:3.24
RUN apk add --no-cache openssh-server \
 && adduser -D -s /bin/sh -u 1000 dev \
 && sed -i 's/^dev:!:/dev:*:/' /etc/shadow \
 && mkdir -p /etc/ssh/hostkeys
COPY sshd_config /etc/ssh/sshd_config
COPY entrypoint.sh /entrypoint.sh
EXPOSE 22
ENTRYPOINT ["/bin/sh", "/entrypoint.sh"]
