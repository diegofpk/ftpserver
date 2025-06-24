#!/bin/bash

# --- VARIAVEIS DE CONFIGURACAO ---
# Preencha com o dominio do seu servidor FTP
DOMAIN="ftp.sotheinfo.com.br"

# Usuario 1
FTP_USER1="sothe"
FTP_PASS1="sothe" # MUDE AQUI!

# Usuario 2
FTP_USER2="inlog"
FTP_PASS2="inlog" # MUDE AQUI!

# Diretorio base para os usuarios FTP
FTP_BASE_DIR="/srv/ftp_users"

# Porta do VsftpdWeb (pode ser alterada se houver conflito)
VSFTPDWEB_PORT="8080"
# --- FIM DAS VARIAVEIS DE CONFIGURACAO ---

# Funcao para exibir mensagens de status
log_message() {
    echo -e "\n--- $1 ---\n"
}

# Verificar se esta sendo executado como root
if [ "$(id -u)" -ne 0 ]; then
    echo "Este script precisa ser executado como root ou com sudo."
    exit 1
fi

log_message "Atualizando o sistema e instalando dependencias essenciais"
apt update && apt upgrade -y
apt install -y vsftpd python3-pip certbot python3-certbot-nginx nginx fail2ban git

log_message "Configurando o VSFTPD"
# Fazer backup do arquivo de configuracao original
mv /etc/vsftpd.conf /etc/vsftpd.conf.bak

# Criar o novo arquivo de configuracao
cat <<EOF > /etc/vsftpd.conf
listen=NO
listen_ipv6=YES
anonymous_enable=NO
local_enable=YES
write_enable=YES
local_umask=022
dirmessage_enable=YES
use_localtime=YES
xferlog_enable=YES
connect_from_port_20=YES
chown_uploads=NO
chroot_local_user=YES
allow_writeable_chroot=YES # Necessario para VsftpdWeb se o VsftpdWeb estiver no diretorio chroot
secure_low_priv_data_connection=YES
pasv_enable=YES
pasv_min_port=40000
pasv_max_port=50000
rsa_cert_file=/etc/ssl/certs/vsftpd.pem # Este sera gerado pelo script
rsa_private_key_file=/etc/ssl/private/vsftpd.pem # Este sera gerado pelo script
ssl_enable=YES
allow_anon_ssl=NO
force_local_data_ssl=YES
force_local_logins_ssl=YES
ssl_tlsv1_2=YES
ssl_sslv2=NO
ssl_sslv3=NO
require_ssl_reuse=NO
debug_ssl=NO
dirlist_enable=YES
download_enable=YES
ascii_upload_enable=NO
ascii_download_enable=NO
# Per-user configuration directories (for user-specific settings)
user_config_dir=/etc/vsftpd_user_conf
# Log file location
xferlog_file=/var/log/vsftpd.log
EOF

log_message "Criando diretorios para configuracoes de usuario VSFTPD"
mkdir -p /etc/vsftpd_user_conf
chmod 700 /etc/vsftpd_user_conf

log_message "Criando diretorio base para usuarios FTP"
mkdir -p "$FTP_BASE_DIR"
chmod 755 "$FTP_BASE_DIR"

log_message "Criando usuarios FTP e seus diretorios"
# Usuario 1
if id "$FTP_USER1" &>/dev/null; then
    log_message "Usuario $FTP_USER1 ja existe. Pulando criacao."
else
    useradd -m -d "$FTP_BASE_DIR/$FTP_USER1" "$FTP_USER1"
    echo "$FTP_USER1:$FTP_PASS1" | chpasswd
    chmod 750 "$FTP_BASE_DIR/$FTP_USER1"
    chown "$FTP_USER1":"$FTP_USER1" "$FTP_BASE_DIR/$FTP_USER1"
    echo "local_root=$FTP_BASE_DIR/$FTP_USER1" > "/etc/vsftpd_user_conf/$FTP_USER1"
    log_message "Usuario $FTP_USER1 criado com sucesso."
fi

# Usuario 2
if id "$FTP_USER2" &>/dev/null; then
    log_message "Usuario $FTP_USER2 ja existe. Pulando criacao."
else
    useradd -m -d "$FTP_BASE_DIR/$FTP_USER2" "$FTP_USER2"
    echo "$FTP_USER2:$FTP_PASS2" | chpasswd
    chmod 750 "$FTP_BASE_DIR/$FTP_USER2"
    chown "$FTP_USER2":"$FTP_USER2" "$FTP_BASE_DIR/$FTP_USER2"
    echo "local_root=$FTP_BASE_DIR/$FTP_USER2" > "/etc/vsftpd_user_conf/$FTP_USER2"
    log_message "Usuario $FTP_USER2 criado com sucesso."
fi

# Gerar certificado SSL autoassinado para o VSFTPD temporariamente
# O Let's Encrypt será usado para o Nginx e a interface web
log_message "Gerando certificado SSL autoassinado temporario para VSFTPD"
openssl req -x509 -nodes -days 365 -newkey rsa:2048 -keyout /etc/ssl/private/vsftpd.pem -out /etc/ssl/certs/vsftpd.pem -subj "/CN=$DOMAIN/O=SotheInfo/OU=FTP"

log_message "Reiniciando VSFTPD para aplicar configuracoes"
systemctl restart vsftpd
systemctl enable vsftpd

log_message "Instalando VsftpdWeb"
cd /opt
git clone https://github.com/Tvel/VsftpdWeb.git
cd VsftpdWeb
pip3 install -r requirements.txt

# Configurar VsftpdWeb para iniciar no boot
log_message "Configurando VsftpdWeb como servico systemd"
cat <<EOF > /etc/systemd/system/vsftpdweb.service
[Unit]
Description=VsftpdWeb Admin Interface
After=network.target

[Service]
User=root # Ou um usuario com acesso aos arquivos de configuracao do vsftpd
WorkingDirectory=/opt/VsftpdWeb
ExecStart=/usr/bin/python3 app.py --port $VSFTPDWEB_PORT
Restart=always

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl start vsftpdweb
systemctl enable vsftpdweb

log_message "Configurando Nginx para proxy reverso e Let's Encrypt"
# Remover configuracao padrao do Nginx
rm -f /etc/nginx/sites-enabled/default
rm -f /etc/nginx/sites-available/default

# Criar configuracao do Nginx para o seu dominio
cat <<EOF > /etc/nginx/sites-available/$DOMAIN
server {
    listen 80;
    server_name $DOMAIN;

    location / {
        proxy_pass http://127.0.0.1:$VSFTPDWEB_PORT;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF

ln -s /etc/nginx/sites-available/$DOMAIN /etc/nginx/sites-enabled/

log_message "Testando configuracao Nginx e reiniciando"
nginx -t && systemctl restart nginx

log_message "Obtendo certificado SSL com Let's Encrypt via Certbot"
# O Certbot ira pausar o Nginx, obter o certificado e reconfigurar o Nginx para HTTPS
certbot --nginx -d $DOMAIN --agree-tos --email your_email@example.com --no-eff-email # MUDE O EMAIL!

# Verificar se o certificado foi criado e atualizar o VSFTPD para usar o certificado do Let's Encrypt
if [ -f "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ] && [ -f "/etc/letsencrypt/live/$DOMAIN/privkey.pem" ]; then
    log_message "Certificado Let's Encrypt obtido com sucesso! Atualizando VSFTPD."
    sed -i "s|rsa_cert_file=.*|rsa_cert_file=/etc/letsencrypt/live/$DOMAIN/fullchain.pem|" /etc/vsftpd.conf
    sed -i "s|rsa_private_key_file=.*|rsa_private_key_file=/etc/letsencrypt/live/$DOMAIN/privkey.pem|" /etc/vsftpd.conf
    systemctl restart vsftpd
else
    log_message "ATENCAO: Falha ao obter certificado Let's Encrypt. O FTP ainda pode usar um certificado autoassinado."
fi

log_message "Configurando Fail2Ban para VSFTPD e SSH"
cat <<EOF > /etc/fail2ban/jail.d/vsftpd.conf
[vsftpd]
enabled = true
port = ftp,ftp-data,ftps,ftps-data
filter = vsftpd
logpath = /var/log/vsftpd.log
maxretry = 5
bantime = 1h
EOF

cat <<EOF > /etc/fail2ban/filter.d/vsftpd.conf
[Definition]
failregex = ^.+ authentication failure; logname=\S* uid=\S* euid=\S* tty=\S* ruser=\S* rhost=<HOST> user=\S*$
            ^.+ FTP Login incorrect, possibly a brute force attack\.$
            ^.+ \[pid \d+\] \[client <HOST>\]: FTP LOGIN FAILED: 530 Login incorrect\.$
ignoreregex =
EOF

log_message "Reiniciando Fail2Ban para aplicar configuracoes"
systemctl restart fail2ban
systemctl enable fail2ban

log_message "Configuracao Concluida!"
echo "------------------------------------------------------------------"
echo "Seu servidor FTP e interface web estao configurados!"
echo "Acesse a interface web (VsftpdWeb) em: https://$DOMAIN"
echo "Credenciais FTP para Usuario 1:"
echo "  Usuario: $FTP_USER1"
echo "  Senha: $FTP_PASS1"
echo "Credenciais FTP para Usuario 2:"
echo "  Usuario: $FTP_USER2"
echo "  Senha: $FTP_PASS2"
echo "------------------------------------------------------------------"
echo "LEMBRE-SE DE TESTAR O ACESSO FTP E A INTERFACE WEB!"
echo "VERIFIQUE TAMBEM OS LOGS DO FAIL2BAN: journalctl -u fail2ban"
echo "Para acessar a pasta do $FTP_USER1 via FTP, o caminho sera / ou /files (dependendo do seu cliente FTP)."
echo "O diretorio real no servidor eh: $FTP_BASE_DIR/$FTP_USER1"
