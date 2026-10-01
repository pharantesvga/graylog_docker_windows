ARG GRAYLOG_BASE_IMAGE=graylog/graylog:7.0
FROM ${GRAYLOG_BASE_IMAGE}

LABEL maintainer="seg35-graylog lab"
LABEL description="Imagem Graylog 7.0 customizada: timezone America/Sao_Paulo + chrony como cliente NTP do linserver"

# A imagem oficial do Graylog roda como usuário não-root 'graylog' (uid 1100).
# Voltamos a root temporariamente para instalar pacotes e ajustar o sistema;
# o wrapper de entrypoint devolve a execução para o usuário graylog no final.
USER root

ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=America/Sao_Paulo
ENV GOSU_VERSION=1.17

# A imagem base do Graylog vem com as fontes do apt bem restritas (só o
# essencial para rodar o Java/Graylog) — pacotes comuns como iproute2, ucf,
# tzdata-legacy e libedit2 (dependências do chrony) não estão disponíveis
# nela. Substituímos por um arquivo apontando para o arquivo COMPLETO do
# Ubuntu (main + restricted + universe + multiverse), garantindo que o
# chrony e todas as suas dependências sejam resolvíveis normalmente.
RUN . /etc/os-release && \
    CODENAME="${VERSION_CODENAME}" && \
    { \
        echo "deb http://archive.ubuntu.com/ubuntu ${CODENAME} main restricted universe multiverse"; \
        echo "deb http://archive.ubuntu.com/ubuntu ${CODENAME}-updates main restricted universe multiverse"; \
        echo "deb http://security.ubuntu.com/ubuntu ${CODENAME}-security main restricted universe multiverse"; \
    } > /etc/apt/sources.list.d/full-archive.list && \
    cat /etc/apt/sources.list.d/full-archive.list

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        tzdata \
        chrony \
        ca-certificates \
        wget \
        gnupg \
        openssl && \
    rm -rf /var/lib/apt/lists/*

# ---------------------------------------------------------------------
# rsyslog + sshd + Filebeat: necessários para que o próprio container
# graylog gere e colete seus próprios logs de autenticação SSH (stream
# auth_graylog). Nenhum dos três vem por padrão na imagem oficial do
# Graylog — foram identificados como ausentes durante troubleshooting
# manual e são persistidos aqui para sobreviver a rebuilds.
#
# ⚠️ Instalar aqui só garante a PRESENÇA dos binários na imagem. Os três
# serviços ainda precisam ser iniciados em runtime (rsyslogd, sshd,
# filebeat) — isso deve ser feito em entrypoint-wrapper.sh, não neste
# Dockerfile. Ver observação no final do arquivo/handover.
# ---------------------------------------------------------------------
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        rsyslog \
        openssh-server && \
    rm -rf /var/lib/apt/lists/* && \
    mkdir -p /run/sshd

# Repositório oficial do Elastic para o Filebeat. Usamos a série 8.x,
# validada nesta sessão como compatível com o restante do ambiente.
RUN curl -fsSL https://artifacts.elastic.co/GPG-KEY-elasticsearch | \
        gpg --dearmor -o /usr/share/keyrings/elastic.gpg && \
    echo "deb [signed-by=/usr/share/keyrings/elastic.gpg] https://artifacts.elastic.co/packages/8.x/apt stable main" \
        > /etc/apt/sources.list.d/elastic-8.x.list && \
    apt-get update && \
    apt-get install -y --no-install-recommends filebeat && \
    rm -rf /var/lib/apt/lists/*

# Config do Filebeat específica deste container (lê /var/log/*.log deste
# host e envia para o input Beats do próprio Graylog, em localhost:5044 —
# ver filebeat.yml para o raciocínio completo, incluindo o caminho real
# do certificado TLS neste ambiente, diferente do usado no linserver).
COPY filebeat.yml /etc/filebeat/filebeat.yml

# Corrige o timezone da imagem
RUN ln -snf /usr/share/zoneinfo/${TZ} /etc/localtime && \
    echo "${TZ}" > /etc/timezone

# gosu: baixado direto do GitHub (evita depender do apt para isso)
RUN dpkgArch="$(dpkg --print-architecture)" && \
    wget -q -O /usr/local/bin/gosu \
        "https://github.com/tianon/gosu/releases/download/${GOSU_VERSION}/gosu-${dpkgArch}" && \
    chmod +x /usr/local/bin/gosu && \
    gosu nobody true

# Configura o chrony como cliente NTP do linserver, removendo pools/servidores
# padrão
RUN sed -i 's/^\(pool .*\)/#\1/; s/^\(server .*\)/#\1/' /etc/chrony/chrony.conf && \
    echo "server linserver iburst" >> /etc/chrony/chrony.conf

# Copia o wrapper de entrypoint (já responsável por iniciar rsyslogd,
# sshd e Filebeat, nessa ordem, antes de repassar a execução para o
# entrypoint original do Graylog — ver entrypoint-wrapper.sh)
COPY entrypoint-wrapper.sh /usr/local/bin/entrypoint-wrapper.sh
RUN chmod +x /usr/local/bin/entrypoint-wrapper.sh

ENTRYPOINT ["/usr/local/bin/entrypoint-wrapper.sh"]
