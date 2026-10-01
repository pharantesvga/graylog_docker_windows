ARG TAG=26.04
# Primeiro estágio: instalação e configuração base
FROM ubuntu:$TAG AS builder

LABEL maintainer="Luiz Claubert, <luizclaubertss@gmail.com>"
LABEL version="v0.3"

# Evita prompts interativos durante a instalação
ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=America/Sao_Paulo

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        autoconf \
        build-essential \
        ca-certificates \
        dpkg-dev \
        lsb-release \
        git \
        libtool \
        libltdl-dev \
        sudo \
        inetutils-ping net-tools iproute2 ufw tcpdump \
        curl wget vim nano \
        openssh-server openssh-client \
        apt-transport-https software-properties-common && \
    rm -rf /var/lib/apt/lists/*

# Cria usuário 'aluno' com senha 'rnpesr' e acesso sudo
RUN useradd -m -s /bin/bash aluno && \
    echo "aluno:rnpesr" | chpasswd && \
    usermod -aG sudo aluno

# Troca a senha do root
RUN echo "root:rnpesr" | chpasswd

# Instalar suporte a português
RUN apt-get update && \
    apt-get install -y language-pack-pt language-pack-pt-base && \
    update-locale LANG=pt_BR.UTF-8 && \
    rm -rf /var/lib/apt/lists/*

# -------------------------
# Segundo estágio: build final
FROM ubuntu:$TAG

LABEL maintainer="Luiz Claubert, <luizclaubertss@gmail.com>"
LABEL version="v0.3"

# Evita prompts interativos durante a instalação
ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=America/Sao_Paulo
ENV LANG=pt_BR.UTF-8

# Instala pacotes essenciais: SSH, utilitários, LDAP e NTP (chrony)
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        gnupg \
        inetutils-ping \
        iproute2 \
        locales \
        nano \
        net-tools \
        openssh-client \
        openssh-server \
        software-properties-common \
        sudo \
        tcpdump \
        ufw \
        vim \
        wget \
        # --- LDAP server e utilitários ---
        slapd \
        ldap-utils \
        libldap-dev \
        # --- Cliente/servidor NTP ---
        chrony \
        # --- Encaminhamento de logs ---
        rsyslog && \
    rm -rf /var/lib/apt/lists/*

# Integração do NSS (getent) com o LDAP, via nss-pam-ldapd (nslcd).
# Fazemos o preseed do debconf ANTES de instalar os pacotes para evitar que
# o apt trave esperando resposta interativa durante o build (o nslcd/
# libnss-ldapd normalmente perguntam URI do LDAP, base DN e quais bases de
# dados do NSS devem consultar o LDAP).
RUN echo "nslcd nslcd/ldap-uris string ldap://localhost/" | debconf-set-selections && \
    echo "nslcd nslcd/ldap-base string dc=example,dc=com" | debconf-set-selections && \
    echo "libnss-ldapd libnss-ldapd/nsswitch multiselect group, passwd, shadow" | debconf-set-selections && \
    DEBIAN_FRONTEND=noninteractive apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        libnss-ldapd \
        nslcd && \
    rm -rf /var/lib/apt/lists/*

# Rede de segurança: garante que passwd/group/shadow consultem o LDAP no
# /etc/nsswitch.conf, mesmo que o debconf não tenha feito essa edição
RUN for db in passwd group shadow; do \
        grep -qE "^${db}:.*ldap" /etc/nsswitch.conf || \
        sed -i "s/^${db}:\(.*\)$/${db}:\1 ldap/" /etc/nsswitch.conf; \
    done && \
    cat /etc/nsswitch.conf

# Configura o locale pt_BR
RUN locale-gen pt_BR.UTF-8 && update-locale LANG=pt_BR.UTF-8

# Libera o chrony para responder consultas NTP vindas de outros containers
# da rede Docker (ex.: graylog), não apenas de localhost
RUN echo "allow 172.16.0.0/12" >> /etc/chrony/chrony.conf && \
    echo "allow 192.168.0.0/16" >> /etc/chrony/chrony.conf

# Configura SSH:
# - habilita autenticação por senha
# - permite login root (útil para testes/laboratório)
# - garante que o diretório de runtime do sshd exista
RUN sed -i \
        -e 's/#PasswordAuthentication yes/PasswordAuthentication yes/' \
        -e 's/PasswordAuthentication no/PasswordAuthentication yes/' \
        -e 's/#PermitRootLogin prohibit-password/PermitRootLogin yes/' \
        /etc/ssh/sshd_config && \
    mkdir -p /var/run/sshd && \
    chmod 755 /var/run/sshd

# Cria usuário 'aluno' com senha 'rnpesr' e acesso sudo
RUN useradd -m -s /bin/bash aluno && \
    echo "aluno:rnpesr" | chpasswd && \
    usermod -aG sudo aluno

# Troca a senha do root
RUN echo "root:rnpesr" | chpasswd

# Instala a ferramenta 'up' (https://github.com/akavel/up) v0.4
RUN wget -q -O /usr/local/bin/up \
        https://github.com/akavel/up/releases/download/v0.4/up && \
    chmod +x /usr/local/bin/up

# ---------------------------------------------------------------------
# Nginx e Squid — instalados já no build da imagem (idempotente: nenhum
# desses pacotes precisa ser reinstalado manualmente após recriação do
# container, diferente do que ocorria quando eram instalados "ao vivo"
# ao longo de uma sessão). O start em si continua sendo feito pelo
# entrypoint a cada boot, já que "apt install" não sobe o serviço neste
# ambiente sem systemd (invoke-rc.d/policy-rc.d nega o start durante o
# build, silenciosamente — ver armadilha correspondente no handover).
# ---------------------------------------------------------------------
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        nginx \
        squid && \
    rm -rf /var/lib/apt/lists/*

# Squid: access_log via syslog (facility local7), encaminhado pelo rsyslog
# para /var/log/squid/access.log (regra copiada abaixo). Neste desenho,
# quem efetivamente escreve o arquivo é o rsyslogd (usuário "syslog"), não
# o Squid — o arquivo precisa pertencer a "syslog", não a "proxy" (dono
# padrão de /var/log/squid/). Confirmado por teste real: com o arquivo
# pertencendo a "proxy", o rsyslog falhava silenciosamente e a mensagem
# caía no /var/log/syslog genérico em vez do arquivo esperado.
RUN grep -q "^access_log" /etc/squid/squid.conf || \
        echo "access_log syslog:local7.info squid" >> /etc/squid/squid.conf && \
    mkdir -p /var/log/squid && \
    touch /var/log/squid/access.log && \
    chown syslog:syslog /var/log/squid/access.log

COPY files/squid-rsyslog.conf /etc/rsyslog.d/49-squid.conf

# Nginx: reverse proxy único para a UI do Graylog (graylog.esr /
# graylog.esr.local -> http://graylog:9000), permitindo acessá-la via
# navegador sem especificar porta.
COPY files/nginx-default.conf /etc/nginx/sites-available/default
COPY files/nginx-upgrade-map.conf /etc/nginx/conf.d/upgrade-map.conf
RUN nginx -t

# ---------------------------------------------------------------------
# Filebeat — instalado a partir do repositório oficial Elastic 8.x
# (não disponível nos repositórios padrão do Ubuntu), também já no build
# da imagem pelo mesmo motivo do Nginx/Squid acima.
# ---------------------------------------------------------------------
RUN wget -qO - https://artifacts.elastic.co/GPG-KEY-elasticsearch | \
        gpg --dearmor -o /usr/share/keyrings/elastic.gpg && \
    echo "deb [signed-by=/usr/share/keyrings/elastic.gpg] https://artifacts.elastic.co/packages/8.x/apt stable main" \
        > /etc/apt/sources.list.d/elastic-8.x.list && \
    apt-get update && \
    apt-get install -y --no-install-recommends filebeat && \
    rm -rf /var/lib/apt/lists/*

# O certificado CA (beats.crt) referenciado no filebeat.yml é lido, em
# runtime, de /etc/graylog-ssl — montado a partir do volume compartilhado
# "graylog_ssl" (ver docker-compose.yml). Não existe no momento do build.
COPY files/filebeat.yml /etc/filebeat/filebeat.yml
RUN chmod 600 /etc/filebeat/filebeat.yml

# Copia o entrypoint
COPY entrypoint.sh /usr/bin/entrypoint
RUN chmod +x /usr/bin/entrypoint

# Faz clone dos arquivos do projeto
COPY seg35-files /root/seg35-files

# Instalar docker
RUN apt-get remove -y docker docker-engine docker.io containerd runc || true && \
    apt-get update && \
    apt-get install -y apt-transport-https ca-certificates curl gnupg lsb-release && \
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg && \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" > /etc/apt/sources.list.d/docker.list && \
    apt-get update && \
    apt-get install -y docker-ce docker-ce-cli containerd.io

# pacotes do squid
RUN apt install -y squid elinks

RUN apt install -y nginx jq sysstat


# Expõe SSH (22), NTP (123/udp) e HTTP (80 — Nginx, com reverse proxy
# para a UI do Graylog)
EXPOSE 22/tcp
EXPOSE 123/udp
EXPOSE 80/tcp

# Limpar o apt
RUN apt-get clean && rm -rf /var/lib/apt/lists/*

ENTRYPOINT ["/usr/bin/entrypoint"]
