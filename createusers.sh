#!/bin/bash

# --- VARIAVEIS DE CONFIGURACAO DOS USUARIOS ---
# Preencha com os detalhes dos seus usuarios FTP
FTP_BASE_DIR="/srv/ftp_users" # Diretorio raiz onde os diretorios dos usuarios serao criados

# Usuario 1
FTP_USER1="diego"
FTP_PASS1="SuaSenhaForteAqui123!" # MUDE AQUI! SENHA FORTE E UNICA!

# Usuario 2
FTP_USER2="sotheinfo"
FTP_PASS2="OutraSenhaForteAqui456!" # MUDE AQUI! SENHA FORTE E UNICA!
# --- FIM DAS VARIAVEIS DE CONFIGURACAO ---

log_message() {
    echo -e "\n--- $1 ---\n"
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
    echo "Este script precisa ser executado como root ou com sudo."
    exit 1
fi

log_message "Iniciando configuracao de usuarios VSFTPD"

# Criar o diretorio base para os usuarios FTP se nao existir
if [ ! -d "$FTP_BASE_DIR" ]; then
    log_message "Criando diretorio base FTP: $FTP_BASE_DIR"
    sudo mkdir -p "$FTP_BASE_DIR"
    sudo chmod 755 "$FTP_BASE_DIR"
fi

# Criar diretorio para configuracoes de usuario VSFTPD se nao existir
if [ ! -d "/etc/vsftpd_user_conf" ]; then
    log_message "Criando diretorio /etc/vsftpd_user_conf"
    sudo mkdir -p /etc/vsftpd_user_conf
    sudo chmod 700 /etc/vsftpd_user_conf
fi

# Loop para configurar cada usuario
for USERNAME in "$FTP_USER1" "$FTP_USER2"; do
    USER_PASSWORD=""
    if [ "$USERNAME" == "$FTP_USER1" ]; then
        USER_PASSWORD="$FTP_PASS1"
    elif [ "$USERNAME" == "$FTP_USER2" ]; then
        USER_PASSWORD="$FTP_PASS2"
    fi

    log_message "Configurando usuario: $USERNAME"

    # 1. Criar o usuario do sistema, se nao existir
    if id "$USERNAME" &>/dev/null; then
        echo "Usuario do sistema '$USERNAME' ja existe. Pulando criacao."
    else
        confirm_action "Usuario do sistema '$USERNAME' nao existe. Deseja cria-lo?" && {
            sudo useradd -m -d "$FTP_BASE_DIR/$USERNAME" "$USERNAME" # Cria o home, mas as permissoes serao ajustadas
            echo "$USERNAME:$USER_PASSWORD" | sudo chpasswd
            echo "Usuario do sistema '$USERNAME' criado com sucesso com senha."
        } || {
            echo "Ignorando criacao do usuario do sistema '$USERNAME'."
            continue # Pula para o proximo usuario no loop
        }
    fi

    # 2. Definir a estrutura de diretorios para o VSFTPD (Opcao Segura)
    USER_CHROOT_DIR="$FTP_BASE_DIR/$USERNAME"
    USER_UPLOAD_DIR="$USER_CHROOT_DIR/uploads"

    # Remover diretorio existente se o usuario confirmar para recriar limpo
    if [ -d "$USER_CHROOT_DIR" ]; then
        confirm_action "Diretorio '$USER_CHROOT_DIR' ja existe. Remover e recriar para garantir permissoes corretas?" && {
            sudo rm -rf "$USER_CHROOT_DIR"
            echo "Diretorio '$USER_CHROOT_DIR' removido."
        }
    fi

    # Criar diretorio chroot base (propriedade ROOT e nao gravavel pelo usuario FTP)
    echo "Criando diretorio chroot base: $USER_CHROOT_DIR"
    sudo mkdir -p "$USER_CHROOT_DIR"
    sudo chmod 550 "$USER_CHROOT_DIR" # r-xr-x--- (nao gravavel pelo usuario FTP)
    sudo chown root:root "$USER_CHROOT_DIR" # Propriedade do root
    echo "Permissoes para $USER_CHROOT_DIR:"
    ls -ld "$USER_CHROOT_DIR"

    # Criar subdiretorio gravavel para o usuario FTP
    echo "Criando subdiretorio de upload: $USER_UPLOAD_DIR"
    sudo mkdir -p "$USER_UPLOAD_DIR"
    sudo chown "$USERNAME":"$USERNAME" "$USER_UPLOAD_DIR" # Propriedade do usuario FTP
    sudo chmod 770 "$USER_UPLOAD_DIR" # rwxrwx--- (gravavel pelo usuario FTP e seu grupo)
    echo "Permissoes para $USER_UPLOAD_DIR:"
    ls -ld "$USER_UPLOAD_DIR"

    # 3. Criar e configurar o arquivo de configuracao por usuario
    VSFTPD_USER_CONF_FILE="/etc/vsftpd_user_conf/$USERNAME"
    echo "Criando/atualizando arquivo de configuracao para $USERNAME: $VSFTPD_USER_CONF_FILE"
    echo "local_root=$USER_CHROOT_DIR" | sudo tee "$VSFTPD_USER_CONF_FILE" > /dev/null
    echo "Arquivo $VSFTPD_USER_CONF_FILE criado com conteudo:"
    cat "$VSFTPD_USER_CONF_FILE"

done

log_message "Reiniciando o VSFTPD para aplicar as novas configuracoes de usuario"
confirm_action "Deseja reiniciar o servico VSFTPD agora?" && {
    sudo systemctl restart vsftpd
    sleep 2 # Dar um tempo para o servico iniciar
    sudo systemctl status vsftpd --no-pager
    if sudo systemctl is-active --quiet vsftpd; then
        echo "VSFTPD reiniciado com sucesso. Usuarios configurados."
        echo "Lembre-se de instruir os usuarios a enviar arquivos para a pasta 'uploads' dentro de seu diretorio."
    else
        echo "AVISO: VSFTPD falhou ao reiniciar. Verifique 'sudo systemctl status vsftpd' e 'sudo journalctl -u vsftpd.service' para erros."
        echo "Isso pode indicar um problema na sua configuracao principal do vsftpd.conf, nao relacionada a criacao de usuarios."
    fi
} || {
    echo "VSFTPD nao reiniciado. Lembre-se de reinicia-lo manualmente mais tarde para aplicar as alteracoes:"
    echo "sudo systemctl restart vsftpd"
}

log_message "Configuracao de usuarios VSFTPD concluida!"
echo "---------------------------------------------------"
echo "Usuarios configurados:"
echo "  Usuario 1: $FTP_USER1"
echo "  Senha 1: $FTP_PASS1"
echo "  Diretorio de upload: /uploads (dentro do chroot FTP)"
echo "  Usuario 2: $FTP_USER2"
echo "  Senha 2: $FTP_PASS2"
echo "  Diretorio de upload: /uploads (dentro do chroot FTP)"
echo "---------------------------------------------------"
echo "Testar com um cliente FTP (FileZilla, Cyberduck, etc.)"
