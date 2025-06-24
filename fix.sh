#!/bin/bash

# --- VARIAVEIS DE CONFIGURACAO ---
FTP_BASE_DIR="/srv/ftp_users"
FTP_USER1="usuario1"
FTP_PASS1="SuaSenhaForte123!" # Confirme esta senha se for recriar
FTP_USER2="usuario2"
FTP_PASS2="OutraSenhaForte456!" # Confirme esta senha se for recriar
DOMAIN="ftp.sotheinfo.com.br"
EMAIL_LE="your_email@example.com" # MUDE O EMAIL para o Certbot
# --- FIM DAS VARIAVEIS DE CONFIGURACAO ---

log_step() {
    echo -e "\n>>> PASSO: $1 <<<"
}

confirm_action() {
    read -p "Deseja executar esta acao? (s/N): " choice
    case "$choice" in
        s|S ) return 0 ;;
        * ) return 1 ;;
    esac
}

# Verificar se esta sendo executado como root
if [ "$(id -u)" -ne 0 ]; then
    echo "Este script de correcao precisa ser executado como root ou com sudo."
    exit 1
fi

echo "Bem-vindo ao Script de Correcao Interativa do Servidor FTP (VSFTPD)."
echo "Este script tentara diagnosticar e corrigir os problemas mais comuns."
echo "Ele ira fazer alteracoes no seu sistema. Prossiga com cautela."

confirm_action "Deseja continuar com o script de correcao?" || exit 0

log_step "Verificando e Tentando Iniciar VSFTPD"
sudo systemctl status vsftpd --no-pager
if ! sudo systemctl is-active --quiet vsftpd; then
    echo "VSFTPD nao esta ativo. Tentando iniciar..."
    confirm_action "Tentar iniciar o vsftpd?" && sudo systemctl start vsftpd
    sleep 2
    sudo systemctl status vsftpd --no-pager
    if sudo systemctl is-active --quiet vsftpd; then
        echo "VSFTPD iniciado com sucesso. Verifique se o problema foi resolvido."
        exit 0
    else
        echo "VSFTPD ainda falhou ao iniciar. Prossiga com a correcao da configuracao."
    fi
fi

log_step "Escolha da Estrategia de Chroot"
echo "O VSFTPD é muito sensivel a permissoes no diretorio chroot."
echo "Opcao 1 (Recomendado/Seguro): Diretorio chroot (base do usuario) sera de ROOT e nao gravavel pelo usuario. O usuario gravará em um subdiretorio 'uploads'."
echo "Opcao 2 (Menos Seguro): Diretorio chroot (base do usuario) sera de ROOT e o VSFTPD tentara permitir escrita nele (com 'allow_writeable_chroot=YES'). Ainda assim, é mais seguro criar um subdiretorio 'uploads' para o usuario."
read -p "Escolha a opcao (1 para Seguro, 2 para Menos Seguro): " CHROOT_OPTION

if [[ "$CHROOT_OPTION" != "1" && "$CHROOT_OPTION" != "2" ]]; then
    echo "Opcao invalida. Assumindo Opcao 1 (Segura)."
    CHROOT_OPTION="1"
fi

log_step "Corrigindo Configuracao Principal do VSFTPD (/etc/vsftpd.conf)"
if confirm_action "Fazer backup e editar /etc/vsftpd.conf?"; then
    sudo cp /etc/vsftpd.conf /etc/vsftpd.conf.bak_$(date +%Y%m%d%H%M%S)

    # Definir listen e listen_ipv6 para evitar conflitos
    sudo sed -i 's/^listen=.*/listen=NO/' /etc/vsftpd.conf
    sudo sed -i 's/^listen_ipv6=.*/listen_ipv6=YES/' /etc/vsftpd.conf

    # Definir chroot_local_user
    if ! grep -q "^chroot_local_user=YES" /etc/vsftpd.conf; then
        echo "chroot_local_user=YES" | sudo tee -a /etc/vsftpd.conf
    fi

    # Definir allow_writeable_chroot com base na escolha
    if [ "$CHROOT_OPTION" == "1" ]; then
        sudo sed -i '/^allow_writeable_chroot=/d' /etc/vsftpd.conf # Remove ou comenta
        echo "#allow_writeable_chroot=YES (removido/comentado para seguranca - Opcao 1)" | sudo tee -a /etc/vsftpd.conf
    else # CHROOT_OPTION == 2
        if ! grep -q "^allow_writeable_chroot=YES" /etc/vsftpd.conf; then
            echo "allow_writeable_chroot=YES" | sudo tee -a /etc/vsftpd.conf
        fi
    fi

    # Garantir que os caminhos SSL estao corretos (apontando para Let's Encrypt se possivel)
    if [ -d "/etc/letsencrypt/live/$DOMAIN" ]; then
        sudo sed -i "s|rsa_cert_file=.*|rsa_cert_file=/etc/letsencrypt/live/$DOMAIN/fullchain.pem|" /etc/vsftpd.conf
        sudo sed -i "s|rsa_private_key_file=.*|rsa_private_key_file=/etc/letsencrypt/live/$DOMAIN/privkey.pem|" /etc/vsftpd.conf
        if ! grep -q "^ssl_enable=YES" /etc/vsftpd.conf; then
            echo "ssl_enable=YES" | sudo tee -a /etc/vsftpd.conf
        fi
    else
        echo "AVISO: Certificados Let's Encrypt nao encontrados para $DOMAIN. VSFTPD pode usar auto-assinados ou falhar SSL."
        if ! grep -q "^ssl_enable=YES" /etc/vsftpd.conf; then
            echo "ssl_enable=YES" | sudo tee -a /etc/vsftpd.conf
        fi
        # Gerar certificado SSL autoassinado para o VSFTPD temporariamente se nao existir
        if [ ! -f "/etc/ssl/certs/vsftpd.pem" ] || [ ! -f "/etc/ssl/private/vsftpd.pem" ]; then
            log_step "Gerando certificado SSL autoassinado temporario para VSFTPD"
            confirm_action "Gerar certificado autoassinado temporario?" && {
                sudo openssl req -x509 -nodes -days 365 -newkey rsa:2048 -keyout /etc/ssl/private/vsftpd.pem -out /etc/ssl/certs/vsftpd.pem -subj "/CN=$DOMAIN/O=SotheInfoTemp/OU=FTPTemp"
            }
        fi
    fi

    echo "Edicao de /etc/vsftpd.conf concluida."
    echo "Conteudo atualizado de /etc/vsftpd.conf (linhas relevantes):"
    grep -E '^(listen|listen_ipv6|chroot_local_user|allow_writeable_chroot|ssl_enable|rsa_cert_file|rsa_private_key_file)' /etc/vsftpd.conf
fi

log_step "Corrigindo Diretorios e Permissoes dos Usuarios FTP"
if confirm_action "Corrigir diretorios e permissoes dos usuarios FTP?"; then
    for user in "$FTP_USER1" "$FTP_USER2"; do
        echo "Processando usuario: $user"
        USER_HOME_DIR="$FTP_BASE_DIR/$user"
        VSFTPD_USER_CONF_FILE="/etc/vsftpd_user_conf/$user"

        if [ -d "$USER_HOME_DIR" ]; then
            confirm_action "Remover diretorio existente '$USER_HOME_DIR' para recriar?" && sudo rm -rf "$USER_HOME_DIR"
        fi

        log_step "Criando/Reconfigurando diretorio base (chroot) para $user"
        sudo mkdir -p "$USER_HOME_DIR"

        if [ "$CHROOT_OPTION" == "1" ]; then # Opcao 1: Seguro
            sudo chmod 550 "$USER_HOME_DIR" # Nao gravavel pelo usuario
            sudo chown root:root "$USER_HOME_DIR" # Propriedade do root

            log_step "Criando subdiretorio 'uploads' gravavel para $user"
            sudo mkdir -p "$USER_HOME_DIR/uploads"
            sudo chown "$user":"$user" "$USER_HOME_DIR/uploads"
            sudo chmod 770 "$USER_HOME_DIR/uploads"
            echo "Usuario $user tera acesso a '/uploads' dentro do seu chroot."
        else # Opcao 2: Menos Seguro
            sudo chown root:root "$USER_HOME_DIR" # Propriedade do root
            sudo chmod 755 "$USER_HOME_DIR" # Permissoes para o chroot base

            log_step "Criando subdiretorio 'uploads' gravavel para $user (Mesmo na Opcao 2, boa pratica)"
            sudo mkdir -p "$USER_HOME_DIR/uploads"
            sudo chown "$user":"$user" "$USER_HOME_DIR/uploads"
            sudo chmod 770 "$USER_HOME_DIR/uploads"
            echo "Usuario $user tera acesso a '/uploads' dentro do seu chroot."
            echo "AVISO: Diretorio chroot principal ($USER_HOME_DIR) eh de root. Se o usuario tentar gravar diretamente nele, ainda pode haver problemas, dependendo da versao do VSFTPD e kernel."
        fi

        log_step "Corrigindo arquivo de configuracao para $user ($VSFTPD_USER_CONF_FILE)"
        # Garante que o local_root aponta para o diretorio chroot principal, nao o 'uploads'
        echo "local_root=$USER_HOME_DIR" | sudo tee "$VSFTPD_USER_CONF_FILE"

        # Se os usuarios nao existirem, o script os cria novamente
        if ! id "$user" &>/dev/null; then
            log_step "Usuario $user nao existe. Criando..."
            sudo useradd -m -d "$USER_HOME_DIR" "$user" # Cria o home, mas as permissoes serao ajustadas
            echo "$user:$FTP_PASS1" | sudo chpasswd # Use a senha do usuario 1 para o usuario 1, etc
            echo "Usuario $user criado com sucesso."
        fi

        echo "Detalhes de permissao para $USER_HOME_DIR:"
        ls -ld "$USER_HOME_DIR"
        if [ -d "$USER_HOME_DIR/uploads" ]; then
            echo "Detalhes de permissao para $USER_HOME_DIR/uploads:"
            ls -ld "$USER_HOME_DIR/uploads"
        fi
        echo "Conteudo de $VSFTPD_USER_CONF_FILE:"
        cat "$VSFTPD_USER_CONF_FILE"

    done
    echo "Correcao de diretorios e permissoes concluida."
fi

log_step "Garantindo Fail2Ban Instalado e Configuracoes VSFTPD/SSH Ativas"
if ! command -v fail2ban-client &> /dev/null; then
    confirm_action "Fail2Ban nao esta instalado. Instalar Fail2Ban?" && sudo apt install -y fail2ban
fi

if confirm_action "Garantir configuracoes Fail2Ban para vsftpd e ssh (sobrescrever se existirem)?"; then
    cat <<EOF | sudo tee /etc/fail2ban/jail.d/vsftpd.conf > /dev/null
[vsftpd]
enabled = true
port = ftp,ftp-data,ftps,ftps-data
filter = vsftpd
logpath = /var/log/vsftpd.log
maxretry = 5
bantime = 1h
EOF

    cat <<EOF | sudo tee /etc/fail2ban/filter.d/vsftpd.conf > /dev/null
[Definition]
failregex = ^.+ authentication failure; logname=\S* uid=\S* euid=\S* tty=\S* ruser=\S* rhost=<HOST> user=\S*$
            ^.+ FTP Login incorrect, possibly a brute force attack\.$
            ^.+ \[pid \d+\] \[client <HOST>\]: FTP LOGIN FAILED: 530 Login incorrect\.$
ignoreregex =
EOF
    # Adicionar SSH ao jail.local se nao estiver la
    if ! grep -q "^[sshd]" /etc/fail2ban/jail.local; then
        echo -e "\n[sshd]\nenabled = true" | sudo tee -a /etc/fail2ban/jail.local > /dev/null
    fi

    echo "Configuracoes do Fail2Ban atualizadas. Reiniciando Fail2Ban."
    sudo systemctl restart fail2ban
    sudo systemctl enable fail2ban
    sudo fail2ban-client status vsftpd
    sudo fail2ban-client status sshd
fi

log_step "Reinstalando e Configurando netfilter-persistent"
if ! command -v netfilter-persistent &> /dev/null; then
    confirm_action "netfilter-persistent nao esta instalado. Instalar?" && sudo apt install -y netfilter-persistent
fi

if command -v netfilter-persistent &> /dev/null; then
    confirm_action "Adicionar regras IPTables para FTP e PASV e salvar (sobrescreve existentes!)?" && {
        # Limpa regras existentes para evitar duplicidade antes de adicionar
        sudo iptables -D INPUT -p tcp --dport 21 -j ACCEPT 2>/dev/null
        sudo iptables -D INPUT -p tcp --dport 20 -j ACCEPT 2>/dev/null
        sudo iptables -D INPUT -p tcp --dport 40000:50000 -j ACCEPT 2>/dev/null

        # Adiciona regras
        sudo iptables -A INPUT -p tcp --dport 21 -j ACCEPT
        sudo iptables -A INPUT -p tcp --dport 20 -j ACCEPT
        sudo iptables -A INPUT -p tcp --dport 40000:50000 -j ACCEPT
        sudo netfilter-persistent save
        echo "Regras IPTables atualizadas e salvas."
        sudo iptables -L -n -v | grep -E 'tcp dpt:21|tcp dpts:40000:50000'
    }
fi

log_step "Reiniciando VSFTPD e Testando Conexao Local"
if confirm_action "Reiniciar VSFTPD e testar conexao local (telnet)?"; then
    sudo systemctl restart vsftpd
    sudo systemctl enable vsftpd
    sleep 3 # Dar um tempo para o servico iniciar

    echo "Status final do VSFTPD:"
    sudo systemctl status vsftpd --no-pager

    echo "Tentando telnet localhost 21..."
    timeout 5 telnet localhost 21 || echo "Telnet falhou ou nao respondeu dentro de 5 segundos."
    echo -e "\nSe telnet mostrar 'Connected' e uma mensagem do VSFTPD (220), a porta esta OK localmente."
fi

log_step "Instalacao e Configuração de VsftpdWeb (Verificacao)"
if [ ! -d "/opt/VsftpdWeb" ]; then
    confirm_action "O diretorio /opt/VsftpdWeb nao foi encontrado. Deseja instalar VsftpdWeb?" && {
        log_step "Instalando VsftpdWeb..."
        sudo apt install -y python3-pip git
        cd /opt
        sudo git clone https://github.com/Tvel/VsftpdWeb.git
        cd VsftpdWeb
        sudo pip3 install -r requirements.txt
        log_step "Configurando VsftpdWeb como servico systemd"
        cat <<EOF | sudo tee /etc/systemd/system/vsftpdweb.service > /dev/null
[Unit]
Description=VsftpdWeb Admin Interface
After=network.target

[Service]
User=root
WorkingDirectory=/opt/VsftpdWeb
ExecStart=/usr/bin/python3 app.py --port 8080
Restart=always

[Install]
WantedBy=multi-user.target
EOF
        sudo systemctl daemon-reload
        sudo systemctl start vsftpdweb
        sudo systemctl enable vsftpdweb
        echo "VsftpdWeb instalado e iniciado. Verifique o status com 'sudo systemctl status vsftpdweb'."
    }
else
    echo "VsftpdWeb ja parece estar em /opt/VsftpdWeb."
    confirm_action "Deseja reiniciar o VsftpdWeb?" && {
        sudo systemctl restart vsftpdweb
        sudo systemctl enable vsftpdweb
    }
fi

log_step "Configuracao Nginx e Let's Encrypt (Verificacao)"
if ! command -v nginx &> /dev/null; then
    confirm_action "Nginx nao esta instalado. Instalar?" && sudo apt install -y nginx
fi

if [ ! -f "/etc/nginx/sites-available/$DOMAIN" ]; then
    confirm_action "Arquivo de configuracao Nginx para $DOMAIN nao encontrado. Deseja criar?" && {
        log_step "Criando configuracao Nginx para $DOMAIN"
        sudo rm -f /etc/nginx/sites-enabled/default
        sudo rm -f /etc/nginx/sites-available/default
        cat <<EOF | sudo tee /etc/nginx/sites-available/$DOMAIN > /dev/null
server {
    listen 80;
    server_name $DOMAIN;

    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF
        sudo ln -s /etc/nginx/sites-available/$DOMAIN /etc/nginx/sites-enabled/
        echo "Configuracao Nginx criada. Testando e reiniciando."
        sudo nginx -t && sudo systemctl restart nginx
    }
else
    echo "Configuracao Nginx para $DOMAIN ja existe. Testando e reiniciando Nginx."
    sudo nginx -t && sudo systemctl restart nginx
fi

if confirm_action "Tentar obter/renovar certificado Let's Encrypt para $DOMAIN?"; then
    log_step "Executando Certbot..."
    sudo certbot --nginx -d "$DOMAIN" --agree-tos --email "$EMAIL_LE" --no-eff-email
    if [ -f "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ]; then
        log_step "Certificado Let's Encrypt obtido/renovado com sucesso! Atualizando VSFTPD para usa-lo."
        sudo sed -i "s|rsa_cert_file=.*|rsa_cert_file=/etc/letsencrypt/live/$DOMAIN/fullchain.pem|" /etc/vsftpd.conf
        sudo sed -i "s|rsa_private_key_file=.*|rsa_private_key_file=/etc/letsencrypt/live/$DOMAIN/privkey.pem|" /etc/vsftpd.conf
        sudo systemctl restart vsftpd
    else
        echo "AVISO: Falha ao obter certificado Let's Encrypt. Verifique o dominio e DNS. VSFTPD pode ainda usar certificado autoassinado ou falhar SSL."
    fi
fi

log_step "FIM DO PROCESSO DE CORRECAO"
echo "------------------------------------------------------------------"
echo "Diagnostico e Correcao tentados. Por favor, verifique:"
echo "1. Status do VSFTPD: sudo systemctl status vsftpd"
echo "2. Acesso FTP/FTPS com seu cliente FTP (com credenciais de usuario1/usuario2)."
echo "   - Para FTPS (FTP seguro), seu cliente FTP deve usar conexao explicita com TLS/SSL."
echo "3. Acesso a interface web: https://$DOMAIN (primeiro login: admin/admin, mude imediatamente!)"
echo "4. Se o Fail2Ban esta banindo (apos tentativas erradas): sudo fail2ban-client status vsftpd"
echo "5. Verifique o firewall do seu provedor de nuvem (Proxmox, AWS, etc.) para portas 20, 21, 40000-50000, 80, 443."
echo "------------------------------------------------------------------"
