#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# Este wrapper roda como root (necessário para o chronyd poder ajustar o
# relógio do sistema). Ele sobe o cliente NTP em background e, na sequência,
# repassa a execução para o entrypoint original do Graylog, já com o usuário
# correto (graylog, uid 1100), preservando o comportamento padrão da imagem.
# ---------------------------------------------------------------------------

echo "[entrypoint-wrapper] Horário antes da sincronização:"
date

echo "[entrypoint-wrapper] Iniciando chronyd (cliente NTP -> linserver)..."
mkdir -p /var/run/chrony
/usr/sbin/chronyd || echo "[entrypoint-wrapper] AVISO: chronyd não pôde ser iniciado."

# ---------------------------------------------------------------------------
# O Graylog Sidecar roda como root e recria o diretório
# /var/lib/graylog-sidecar/generated/<config-id>/ toda vez que uma
# configuração de collector é aplicada/alterada (ex.: NXLog, Filebeat).
# Como os próprios collectors costumam derrubar privilégio para um usuário
# de serviço (ex.: "User nxlog" / "Group nxlog" na config do NXLog), esse
# diretório recém-criado fica sem permissão de escrita para esse usuário,
# causando falhas silenciosas do tipo "Permission denied" na fila de saída
# (gelf.q) mesmo com o processo do collector aparentemente rodando.
#
# Para evitar esse problema (e não depender de corrigir manualmente toda
# vez que uma config for reaplicada), rodamos em background um laço que
# corrige a permissão desses diretórios periodicamente.
# ---------------------------------------------------------------------------
echo "[entrypoint-wrapper] Iniciando corretor de permissões do Graylog Sidecar..."
(
    while true; do
        if [ -d /var/lib/graylog-sidecar/generated ]; then
            for dir in /var/lib/graylog-sidecar/generated/*/; do
                [ -d "$dir" ] || continue
                # Descobre qual usuário/grupo o collector dessa pasta espera
                # (declarado na própria config gerada, ex.: "User nxlog")
                conf_file=$(find "$dir" -maxdepth 1 -iname "*.conf" | head -n1)
                if [ -n "$conf_file" ]; then
                    svc_user=$(grep -m1 -oP '^User\s+\K\S+' "$conf_file" 2>/dev/null || true)
                    svc_group=$(grep -m1 -oP '^Group\s+\K\S+' "$conf_file" 2>/dev/null || true)
                    if [ -n "$svc_user" ] && id "$svc_user" >/dev/null 2>&1; then
                        chown -R "${svc_user}:${svc_group:-$svc_user}" "$dir" 2>/dev/null || true
                    fi
                fi
            done
        fi
        sleep 5
    done
) &

# ---------------------------------------------------------------------------
# Certificado TLS auto-assinado para inputs seguros (ex.: Beats/journalbeat
# com TLS). Gerado apenas na primeira execução (idempotente) e persistido no
# volume "graylog_ssl", montado em /etc/graylog/server/ssl — sobrevive a
# recriações do container, evitando invalidar inputs já configurados com TLS.
# ---------------------------------------------------------------------------
SSL_DIR="/etc/graylog/server/ssl"
mkdir -p "${SSL_DIR}"
if [ ! -f "${SSL_DIR}/beats.crt" ] || [ ! -f "${SSL_DIR}/beats.key" ]; then
    echo "[entrypoint-wrapper] Gerando certificado TLS auto-assinado (beats.crt/beats.key)..."
    openssl req -new -newkey rsa:2048 -days 365 -nodes -x509 \
        -subj "/C=BR/ST=DF/L=Brasilia/O=ESR/CN=beats.graylog.esr.local" \
        -keyout "${SSL_DIR}/beats.key" -out "${SSL_DIR}/beats.crt"
else
    echo "[entrypoint-wrapper] Certificado TLS já existente, mantendo (${SSL_DIR})."
fi
chown -R graylog:graylog "${SSL_DIR}"
chmod 700 "${SSL_DIR}"
chmod 600 "${SSL_DIR}/beats.key"
chmod 644 "${SSL_DIR}/beats.crt"

# ---------------------------------------------------------------------------
# rsyslogd: gera /var/log/auth.log a partir das tentativas de login SSH
# neste próprio container (necessário para a stream auth_graylog). Precisa
# subir ANTES do sshd e do Filebeat, já que os dois dependem dele (sshd
# registra via syslog; Filebeat lê o arquivo que o rsyslog escreve).
# ---------------------------------------------------------------------------
echo "[entrypoint-wrapper] Iniciando rsyslogd..."
rsyslogd || echo "[entrypoint-wrapper] AVISO: rsyslogd não pôde ser iniciado."

# ---------------------------------------------------------------------------
# sshd: permite login SSH direto neste container, gerando eventos de
# autenticação para fins de teste/demonstração (stream auth_graylog).
# ssh-keygen -A é idempotente — só gera chaves de host ausentes, não
# sobrescreve as existentes. /run/sshd é recriado aqui porque /run costuma
# ser tmpfs, não sobrevivendo a reinícios do container mesmo que já exista
# na imagem.
# ---------------------------------------------------------------------------
echo "[entrypoint-wrapper] Iniciando sshd..."
mkdir -p /run/sshd
ssh-keygen -A
/usr/sbin/sshd || echo "[entrypoint-wrapper] AVISO: sshd não pôde ser iniciado."

# ---------------------------------------------------------------------------
# Filebeat: coleta /var/log/*.log (incluindo o auth.log gerado pelo rsyslog
# acima) e envia para o input Beats do próprio Graylog, em localhost:5044.
# Diferente de rsyslogd/sshd, o binário do Filebeat não se daemoniza
# sozinho — precisa do "&" explícito para não bloquear o restante do script.
# ---------------------------------------------------------------------------
echo "[entrypoint-wrapper] Iniciando Filebeat..."
mkdir -p /var/log/filebeat
/usr/share/filebeat/bin/filebeat \
    -c /etc/filebeat/filebeat.yml \
    --path.home /usr/share/filebeat \
    --path.config /etc/filebeat \
    --path.data /var/lib/filebeat \
    --path.logs /var/log/filebeat \
    > /var/log/filebeat/filebeat-stdout.log 2>&1 &

echo "[entrypoint-wrapper] Repassando execução para o entrypoint original do Graylog..."
exec gosu graylog /usr/bin/tini -- /docker-entrypoint.sh "$@"
