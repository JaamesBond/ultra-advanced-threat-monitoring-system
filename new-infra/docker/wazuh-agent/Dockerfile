FROM amazonlinux:2023

ARG WAZUH_VERSION=4.14.4

RUN rpm --import https://packages.wazuh.com/key/GPG-KEY-WAZUH && \
    printf '[wazuh]\ngpgcheck=1\ngpgkey=https://packages.wazuh.com/key/GPG-KEY-WAZUH\nenabled=1\nname=EL-$releasever - Wazuh\nbaseurl=https://packages.wazuh.com/4.x/yum/\nprotect=1\n' \
      > /etc/yum.repos.d/wazuh.repo && \
    dnf install -y wazuh-agent-${WAZUH_VERSION}-1 && \
    dnf clean all && \
    rm -rf /var/cache/dnf /tmp/*

# ossec.conf is mounted at runtime from ConfigMap — remove the default
RUN rm -f /var/ossec/etc/ossec.conf

VOLUME ["/var/ossec/queue", "/var/ossec/logs"]
