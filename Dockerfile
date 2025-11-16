FROM debian:trixie-slim

RUN apt-get update && apt-get install -y default-mysql-client s3cmd && apt-get clean && rm -rf /var/cache/apt/archives /var/lib/apt/lists/*.

# Set user and group
ARG user=dbmanager
ARG group=dbmanager
ARG uid=1000
ARG gid=1000
RUN groupadd -g ${gid} ${group}
RUN useradd -u ${uid} -g ${group} -s /bin/sh -m ${user}
COPY cert.bundle.pem /
COPY run.sh /
COPY s3cmd.conf /
RUN chmod +x /run.sh
ENTRYPOINT ["/run.sh"]

# Switch to user
USER ${uid}:${gid}
