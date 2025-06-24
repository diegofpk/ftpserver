#!/bin/bash

# Verifica se foi executado como root
if [[ $EUID -ne 0 ]]; then
   echo "❌ Este script deve ser executado como root."
   exit 1
fi

# Solicita o nome do usuário
read -p "🔐 Digite o nome do usuário FTP: " ftp_user

# Verifica se o usuário existe
if id "$ftp_user" &>/dev/null; then
    # Solicita a nova senha de forma segura
    read -s -p "📝 Digite a nova senha: " ftp_pass
    echo
    read -s -p "📝 Confirme a nova senha: " ftp_pass_confirm
    echo

    if [[ "$ftp_pass" == "$ftp_pass_confirm" ]]; then
        echo "$ftp_user:$ftp_pass" | chpasswd
        echo "✅ Senha do usuário '$ftp_user' alterada com sucesso."
    else
        echo "❌ As senhas não coincidem. Tente novamente."
        exit 2
    fi
else
    echo "❌ Usuário '$ftp_user' não encontrado."
    exit 3
fi
