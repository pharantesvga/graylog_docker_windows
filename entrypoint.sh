#!/usr/bin/env bash
set -euo pipefail
ulimit -n 4096   # logo no início do entrypoint.sh, antes de subir o slapd

# ---------------------------------------------------------------------------
# 1. Cria o usuário 'aluno' caso ainda não exista
# ---------------------------------------------------------------------------
if ! id aluno >/dev/null 2>&1; then
    groupadd --gid 1020 aluno
    useradd \
        --shell /bin/bash \
        --uid 1020 \
        --gid 1020 \
        --groups sudo \
        --password "$(openssl passwd -6 rnpesr)" \
        --create-home \
        --home-dir /home/aluno \
        aluno
fi

# ---------------------------------------------------------------------------
# 2. Garante que o diretório de runtime do sshd existe
# ---------------------------------------------------------------------------
mkdir -p /var/run/sshd
chmod 755 /var/run/sshd

# ---------------------------------------------------------------------------
# 3. Inicia o serviço NTP (chronyd) em background
# ---------------------------------------------------------------------------
echo "[entrypoint] Iniciando chronyd (NTP)..."
mkdir -p /var/run/chrony
chown _chrony:_chrony /var/run/chrony 2>/dev/null || true
/usr/sbin/chronyd 2>/dev/null || echo "[entrypoint] AVISO: chronyd não pôde ser iniciado."

# ---------------------------------------------------------------------------
# 4. Inicia o OpenLDAP (slapd) de forma limpa
#    - mata qualquer processo residual antes de subir
#    - remove socket ldapi residual
#    - sobe diretamente via binário (sem service) para controle total
# ---------------------------------------------------------------------------
LDAP_BASE="dc=example,dc=com"
LDAP_ADMIN_DN="cn=admin,${LDAP_BASE}"
LDAP_ADMIN_PW="rnpesr"
LDAP_DATA_DIR="/var/lib/ldap"
LDAP_CONFIG_DIR="/etc/ldap/slapd.d"
LDAP_SOCKET="/var/run/slapd/ldapi"

echo "[entrypoint] Preparando slapd..."
pkill -9 slapd 2>/dev/null || true
sleep 1
rm -f "${LDAP_SOCKET}"
mkdir -p /var/run/slapd
chown openldap:openldap /var/run/slapd

# ---------------------------------------------------------------------------
# 5. Provisionamento na primeira execução
#    Indicador: arquivo /etc/ldap/.provisioned
# ---------------------------------------------------------------------------
if [ ! -f /etc/ldap/.provisioned ]; then
    echo "[entrypoint] Primeira execução — configurando LDAP..."

    # Limpa banco antigo (evita conflito de suffix dc=nodomain)
    rm -f "${LDAP_DATA_DIR}"/*.mdb "${LDAP_DATA_DIR}"/*.lck 2>/dev/null || true

    # Configura olcSuffix, olcRootDN e olcRootPW diretamente nos arquivos
    # de configuração (slapd parado — sem necessidade de dpkg-reconfigure)
    ADMIN_HASH=$(slappasswd -s "${LDAP_ADMIN_PW}")
    MDB_FILE="${LDAP_CONFIG_DIR}/cn=config/olcDatabase={1}mdb.ldif"

    if [ -f "${MDB_FILE}" ]; then
        sed -i "s|^olcSuffix:.*|olcSuffix: ${LDAP_BASE}|" "${MDB_FILE}"
        sed -i "s|^olcRootDN:.*|olcRootDN: ${LDAP_ADMIN_DN}|" "${MDB_FILE}"
        # Remove linha olcRootPW antiga (se existir) e adiciona a nova
        sed -i '/^olcRootPW/d' "${MDB_FILE}"
        echo "olcRootPW: ${ADMIN_HASH}" >> "${MDB_FILE}"
        # Remove CRC32 antigo — slapd regenera automaticamente na leitura
        sed -i '/^# CRC32/d' "${MDB_FILE}"
    fi

    # Cria entrada raiz no banco MDB via slapadd (slapd ainda parado)
    chown -R openldap:openldap "${LDAP_DATA_DIR}"
    slapadd -F "${LDAP_CONFIG_DIR}" -l /dev/stdin <<LDIF
dn: ${LDAP_BASE}
objectClass: top
objectClass: dcObject
objectClass: organization
o: Example
dc: example
LDIF
    chown -R openldap:openldap "${LDAP_DATA_DIR}"

    echo "[entrypoint] Banco MDB inicializado."
fi

# ---------------------------------------------------------------------------
# 6. Sobe o slapd em background
# ---------------------------------------------------------------------------
echo "[entrypoint] Iniciando slapd..."
/usr/sbin/slapd \
    -h "ldap:/// ldapi:///" \
    -u openldap \
    -g openldap \
    -F "${LDAP_CONFIG_DIR}" 2>/dev/null &

# Aguarda o slapd estar pronto (testa até 10 vezes)
RETRIES=10
until ldapsearch -x -H ldap://localhost \
        -D "${LDAP_ADMIN_DN}" \
        -w "${LDAP_ADMIN_PW}" \
        -b "${LDAP_BASE}" \
        "(objectClass=*)" dn >/dev/null 2>&1; do
    RETRIES=$((RETRIES - 1))
    if [ "${RETRIES}" -eq 0 ]; then
        echo "[entrypoint] ERRO: slapd não respondeu após 10 tentativas." >&2
        break
    fi
    sleep 1
done

# ---------------------------------------------------------------------------
# 7. Adiciona OU e usuário Charlie na primeira execução
# ---------------------------------------------------------------------------
if [ ! -f /etc/ldap/.provisioned ]; then
    echo "[entrypoint] Adicionando ou=users e usuário Charlie..."
    CHARLIE_HASH=$(slappasswd -s "passwd")

    ldapadd -x -H ldap://localhost \
        -D "${LDAP_ADMIN_DN}" \
        -w "${LDAP_ADMIN_PW}" <<LDIF || true
dn: ou=users,${LDAP_BASE}
objectClass: organizationalUnit
ou: users

dn: ou=groups,${LDAP_BASE}
objectClass: organizationalUnit
ou: groups

dn: cn=charlie,ou=users,${LDAP_BASE}
objectClass: inetOrgPerson
objectClass: posixAccount
objectClass: shadowAccount
cn: charlie
sn: Charlie
givenName: Charlie
uid: charlie
uidNumber: 2001
gidNumber: 2001
homeDirectory: /home/charlie
loginShell: /bin/bash
userPassword: ${CHARLIE_HASH}
mail: charlie@example.com

dn: cn=charlie,ou=groups,${LDAP_BASE}
objectClass: posixGroup
cn: charlie
gidNumber: 2001
memberUid: charlie
LDIF

    touch /etc/ldap/.provisioned
    echo "[entrypoint] Usuário Charlie criado com sucesso."
fi

# ---------------------------------------------------------------------------
# 7b. Habilita o log do slapd via syslog (facility local4) e cria o arquivo
#     /etc/rsyslog.d/slapd.conf. Isso NÃO vem por padrão no pacote slapd do
#     Debian/Ubuntu — é provisionado aqui para que o exercício de encaminha-
#     mento de logs (item a/b) funcione exatamente como descrito no roteiro.
# ---------------------------------------------------------------------------
echo "[entrypoint] Habilitando log do slapd (facility local4)..."
ldapmodify -Y EXTERNAL -H ldapi:/// <<LDIF >/dev/null 2>&1 || \
    echo "[entrypoint] AVISO: não foi possível habilitar olcLogLevel."
dn: cn=config
changetype: modify
replace: olcLogLevel
olcLogLevel: stats
LDIF

mkdir -p /etc/rsyslog.d
if [ ! -f /etc/rsyslog.d/slapd.conf ] && [ ! -f /etc/rsyslog.d/10-slapd.conf ]; then
    cat << 'EOF' > /etc/rsyslog.d/10-slapd.conf
$template slapdtmpl,"[%$DAY%-%$MONTH%-%$YEAR% %timegenerated:12:19:date-rfc3339%] %app-name% %syslogseverity-text% %msg%\n"
local4.*    /var/log/slapd.log;slapdtmpl
EOF
fi
touch /var/log/slapd.log
chown syslog:adm /var/log/slapd.log 2>/dev/null || true

# Garante o encaminhamento da facility local4 (slapd) para o Graylog via
# Syslog UDP. Este passo já foi cumprido manualmente como exercício prático
# do laboratório; a partir daqui, ele é provisionado automaticamente para
# que outros exercícios que dependem dele (extractors, pipelines, etc.) não
# quebrem sempre que o container for recriado.
if [ ! -f /etc/rsyslog.d/99-graylog.conf ]; then
    cat << 'EOF' > /etc/rsyslog.d/99-graylog.conf
local4.* @graylog:5140;RSYSLOG_SyslogProtocol23Format
EOF
fi

# ---------------------------------------------------------------------------
# 8. Inicia o rsyslog, já com o encaminhamento para o Graylog configurado
# ---------------------------------------------------------------------------
echo "[entrypoint] Iniciando rsyslogd..."
pkill -9 rsyslogd 2>/dev/null || true
sleep 1
/usr/sbin/rsyslogd 2>/dev/null || echo "[entrypoint] AVISO: rsyslogd não pôde ser iniciado."

# ---------------------------------------------------------------------------
# 8b. Inicia o Nginx
#     - serve como ponto de entrada único na porta 80: um vhost local
#       (linserver) e um reverse proxy para a UI do Graylog
#       (graylog.esr.local -> http://graylog:9000), permitindo acesso via
#       navegador sem especificar porta para nenhum dos dois containers.
#     - não sobrevive a recriação/reinício do container sem este bloco:
#       precisa ser resubido manualmente toda vez, como qualquer serviço
#       instalado via apt neste ambiente (ver seção de particularidades do
#       linserver no handover).
# ---------------------------------------------------------------------------
echo "[entrypoint] Preparando Nginx..."
pkill -9 nginx 2>/dev/null || true
sleep 1
if nginx -t 2>/dev/null; then
    /usr/sbin/nginx || echo "[entrypoint] AVISO: nginx não pôde ser iniciado."
else
    echo "[entrypoint] AVISO: 'nginx -t' falhou — configuração inválida, nginx não foi iniciado."
fi

# ---------------------------------------------------------------------------
# 8c. Inicia o Squid
#     - access_log configurado (via squid.conf, no build da imagem) para
#       "syslog:local7.info squid", encaminhado pelo rsyslog para
#       /var/log/squid/access.log (regra em /etc/rsyslog.d/49-squid.conf).
#     - depende do rsyslogd já estar de pé (seção 8, acima) para não perder
#       as primeiras linhas de log geradas logo após o start.
#     - "squid -z" inicializa os diretórios de cache; só precisa rodar uma
#       vez por volume de dados — aqui é sempre necessário, pois
#       /var/spool/squid não é persistido em volume neste compose.
# ---------------------------------------------------------------------------
echo "[entrypoint] Preparando Squid..."
# "pkill -9 squid" (por nome) não é confiável: o processo mestre chama-se
# "squid", mas o worker aparece como "(squid-1) --kid squid-1" — nome
# diferente, sobrevive ao pkill por nome e fica órfão, escutando a porta
# 3128 sem coordenação com um mestre morto (confirmado via teste real:
# conexões aceitas, mas processadas como 503 TCP_MISS_ABORTED). "-f" casa
# pela linha de comando completa, pegando os dois.
pkill -9 -f squid 2>/dev/null || true
sleep 1
rm -f /run/squid.pid
mkdir -p /var/log/squid
touch /var/log/squid/access.log
chown syslog:syslog /var/log/squid/access.log 2>/dev/null || true
# Este squid.conf não define nenhum "cache_dir" (só cache em memória), ou
# seja, não há diretório de cache em disco para "squid -z" inicializar —
# confirmado: com ou sem esse passo, o comportamento é idêntico. Passo
# removido por ser irrelevante neste ambiente.
/usr/sbin/squid 2>/dev/null || echo "[entrypoint] AVISO: squid não pôde ser iniciado."

# ---------------------------------------------------------------------------
# 8d. Inicia o Filebeat (em background, aguardando o certificado do Graylog)
#     - lê /var/log/*.log, /var/log/squid/*.log e /var/log/nginx/*.log,
#       enviando para graylog:5044 (input Beats TLS).
#     - o CA usado para validar o certificado autoassinado do Graylog
#       (beats.crt) é lido de /etc/graylog-ssl, montado a partir do volume
#       compartilhado "graylog_ssl" (ver docker-compose.yml) — o mesmo
#       volume onde o container graylog grava o certificado no primeiro
#       boot. Como graylog depende do linserver (NTP) e não o contrário,
#       não há garantia de que o arquivo já exista quando este trecho
#       roda; por isso a espera abaixo, em background, para não atrasar a
#       subida do sshd (processo principal do container).
#     - lock de data path (armadilha conhecida) removido antes de cada
#       start, evitando "data path already locked by another beat".
# ---------------------------------------------------------------------------
echo "[entrypoint] Agendando inicialização do Filebeat (aguardando certificado do Graylog)..."
(
    pkill -9 filebeat 2>/dev/null || true
    sleep 1
    rm -f /var/lib/filebeat/filebeat.lock

    CA_CERT="/etc/graylog-ssl/beats.crt"
    RETRIES=60
    until [ -f "${CA_CERT}" ]; do
        RETRIES=$((RETRIES - 1))
        if [ "${RETRIES}" -eq 0 ]; then
            echo "[entrypoint] AVISO: certificado ${CA_CERT} não apareceu a tempo (graylog ainda não subiu?). Filebeat não foi iniciado nesta execução."
            exit 0
        fi
        sleep 3
    done

    echo "[entrypoint] Certificado do Graylog encontrado, iniciando filebeat..."
    /usr/share/filebeat/bin/filebeat -e -c /etc/filebeat/filebeat.yml \
        > /root/filebeat-debug.log 2>&1
) &

# ---------------------------------------------------------------------------
# 9. Inicia o nslcd (integração do NSS/getent com o LDAP)
#    Permite que comandos como "getent passwd charlie" e "getent group
#    charlie" consultem o OpenLDAP local automaticamente, via NSS.
# ---------------------------------------------------------------------------
echo "[entrypoint] Iniciando nslcd (NSS/getent -> LDAP)..."
mkdir -p /var/run/nslcd
chown nslcd:nslcd /var/run/nslcd 2>/dev/null || true
pkill -9 nslcd 2>/dev/null || true
sleep 1
/usr/sbin/nslcd 2>/dev/null || echo "[entrypoint] AVISO: nslcd não pôde ser iniciado."

# ---------------------------------------------------------------------------
# 10. SSH em primeiro plano — processo principal do container
#     Se o sshd terminar, o container reinicia automaticamente
#     (requer --restart=always ou restart: always no compose)
# ---------------------------------------------------------------------------
if [ -z "${1:-}" ]; then
    echo "[entrypoint] Iniciando sshd em foreground..."
    exec /usr/sbin/sshd -D
else
    /usr/sbin/sshd -D &
    exec "$@"
fi
