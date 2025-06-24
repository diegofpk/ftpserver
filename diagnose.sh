#!/bin/bash

# --- VARIAVEIS DE CONFIGURACAO (APENAS PARA DIAGNOSTICO DE CAMINHOS) ---
FTP_BASE_DIR="/srv/ftp_users"
FTP_USER1="usuario1" # Nome de usuario do seu script original
FTP_USER2="usuario2" # Nome de usuario do seu script original
DOMAIN="ftp.sotheinfo.com.br" # Dominio do seu script original
# --- FIM DAS VARIAVEIS DE CONFIGURACAO ---

log_section() {
    echo -e "\n=============================================="
    echo -e " DIAGNOSTICO: $1"
    echo -e "==============================================\n"
}

log_sub_section() {
    echo -e "\n--- $1 ---\n"
}

# Verificar se esta sendo executado como root
if [ "$(id -u)" -ne 0 ]; then
    echo "Este script de diagnostico precisa ser executado como root ou com sudo."
    exit 1
fi

log_section "Verificando Status do Servico VSFTPD"
sudo systemctl status vsftpd --no-pager
echo -e "\nSe o status for 'failed', anote a causa principal do 'Main PID exited'."

log_section "Verificando Logs Recentes do VSFTPD (Ultimas 50 linhas)"
sudo journalctl -u vsftpd.service --since "1 hour ago" -n 50 --no-pager
echo -e "\nProcure por mensagens de erro como 'INVALIDARGUMENT', '500 OOPS', 'SSL' ou 'permission denied'."

log_section "Verificando Configuracao Principal do VSFTPD (/etc/vsftpd.conf)"
log_sub_section "Conteudo do vsftpd.conf (linhas criticas)"
grep -E '^(listen|listen_ipv6|chroot_local_user|allow_writeable_chroot|ssl_enable|rsa_cert_file|rsa_private_key_file)' /etc/vsftpd.conf
echo -e "\nVerifique se 'listen' e 'listen_ipv6' nao estao ambas ativadas/desativadas de forma conflitante."
echo "Verifique 'allow_writeable_chroot' e 'chroot_local_user'."
echo "Verifique os caminhos dos certificados SSL."

log_sub_section "Permissoes do vsftpd.conf"
ls -l /etc/vsftpd.conf

log_section "Verificando Diretorios e Permissoes dos Usuarios FTP"
log_sub_section "Diretorio Base FTP: $FTP_BASE_DIR"
ls -ld "$FTP_BASE_DIR"

for user in "$FTP_USER1" "$FTP_USER2"; do
    log_sub_section "Detalhes para o usuario FTP: $user"
    USER_HOME_DIR="$FTP_BASE_DIR/$user"
    VSFTPD_USER_CONF_FILE="/etc/vsftpd_user_conf/$user"

    echo "Verificando diretorio home/chroot do usuario: $USER_HOME_DIR"
    if [ -d "$USER_HOME_DIR" ]; then
        ls -ld "$USER_HOME_DIR"
        echo "Conteudo do diretorio (primeiro nivel):"
        ls -l "$USER_HOME_DIR"
    else
        echo "Diretorio $USER_HOME_DIR NAO EXISTE."
    fi

    echo "Verificando arquivo de configuracao do usuario: $VSFTPD_USER_CONF_FILE"
    if [ -f "$VSFTPD_USER_CONF_FILE" ]; then
        cat "$VSFTPD_USER_CONF_FILE"
    else
        echo "Arquivo de configuracao $VSFTPD_USER_CONF_FILE NAO EXISTE."
    fi

    # Tentativa de encontrar subdiretorios 'uploads' ou 'public_html'
    if [ -d "$USER_HOME_DIR/uploads" ]; then
        echo "Subdiretorio 'uploads' encontrado:"
        ls -ld "$USER_HOME_DIR/uploads"
    elif [ -d "$USER_HOME_DIR/public_html" ]; then
        echo "Subdiretorio 'public_html' encontrado:"
        ls -ld "$USER_HOME_DIR/public_html"
    fi
done

log_section "Verificando Configuracao de Certificados SSL/TLS"
log_sub_section "Certificado Principal (Let's Encrypt)"
if [ -d "/etc/letsencrypt/live/$DOMAIN" ]; then
    ls -l "/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
    ls -l "/etc/letsencrypt/live/$DOMAIN/privkey.pem"
else
    echo "Diretorio do Let's Encrypt para $DOMAIN NAO ENCONTRADO."
fi

log_sub_section "Certificado VSFTPD (temporario/autoassinado ou Let's Encrypt copiado)"
ls -l /etc/ssl/certs/vsftpd.pem
ls -l /etc/ssl/private/vsftpd.pem

log_section "Verificando Status do Fail2Ban"
sudo systemctl status fail2ban --no-pager
sudo fail2ban-client status vsftpd

log_section "Verificando Regras de Firewall (iptables)"
sudo iptables -L -n -v | grep -E 'tcp dpt:21|tcp dpts:40000:50000'
echo -e "\nVerifique se as portas 21 e o range PASV (40000-50000) estao ACCEPTED na chain INPUT."
echo "Se voce usa outro firewall (ex: no Proxmox ou Cloud Provider), verifique la tambem!"

log_section "Diagnostico Concluido!"
echo "Analise as saidas acima para identificar a causa raiz do problema."
echo "O script de correcao interativo pode ser executado em seguida, se necessario."
