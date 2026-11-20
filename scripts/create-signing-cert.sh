#!/bin/bash
# Creates the stable self-signed code-signing identity used for Oil Find releases.
# A stable identity lets macOS keep Full Disk Access across updates (ad-hoc builds
# get a new identity every time). Run once on the release Mac; keep the backup safe.
set -euo pipefail

NAME="Oil Find Self-Signed"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
BACKUP_DIR="$HOME/Documents/Oil Find Signing"
P12="${BACKUP_DIR}/oil-find-signing.p12"
OPENSSL=/usr/bin/openssl

already_done() {
    if security find-certificate -c "${NAME}" "${KEYCHAIN}" >/dev/null 2>&1; then
        echo "O certificado \"${NAME}\" já existe no keychain — nada a fazer."
        exit 0
    fi
    if [[ -e "${P12}" ]]; then
        echo "O arquivo de backup já existe; cancelando para não sobrescrever: ${P12}"
        echo "Se o certificado do keychain se perder, restaure com: security import \"${P12}\" -k \"${KEYCHAIN}\" -T /usr/bin/codesign"
        exit 1
    fi
}
already_done

echo "Vou criar o certificado de assinatura \"${NAME}\" e exportar um backup criptografado em:"
echo "  ${P12}"
echo
read -r -s -p "Defina uma senha para o arquivo de backup (mínimo 8 caracteres): " PASSWORD; echo
read -r -s -p "Digite a mesma senha novamente: " CONFIRM; echo
[[ "${PASSWORD}" == "${CONFIRM}" ]] || { echo "As senhas não conferem — cancelado."; exit 1; }
[[ ${#PASSWORD} -ge 8 ]] || { echo "A senha precisa ter pelo menos 8 caracteres — cancelado."; exit 1; }
# Check again: another run may have finished while this one waited for the password.
already_done

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
cat > "${WORK}/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = ${NAME}
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
EOF

"${OPENSSL}" req -x509 -newkey rsa:2048 -nodes -days 7300 \
    -keyout "${WORK}/key.pem" -out "${WORK}/cert.pem" -config "${WORK}/cert.cnf" 2>/dev/null

mkdir -p "${BACKUP_DIR}"
P12PASS="${PASSWORD}" "${OPENSSL}" pkcs12 -export -inkey "${WORK}/key.pem" -in "${WORK}/cert.pem" \
    -name "${NAME}" -out "${P12}" -passout env:P12PASS
chmod 600 "${P12}"

echo "Importando para o keychain de login..."
security import "${P12}" -k "${KEYCHAIN}" -P "${PASSWORD}" -T /usr/bin/codesign >/dev/null
echo "Marcando como confiável para assinatura de código (o macOS vai pedir sua senha de login)..."
security add-trusted-cert -r trustRoot -p codeSign -k "${KEYCHAIN}" "${WORK}/cert.pem"

if security find-identity -v -p codesigning "${KEYCHAIN}" | grep -q "${NAME}"; then
    echo
    echo "Pronto! A partir de agora o scripts/build-app.sh assina automaticamente com \"${NAME}\"."
    echo "Se na primeira assinatura aparecer o aviso \"codesign quer acessar a chave no keychain\", escolha \"Sempre Permitir\"."
    echo
    echo "Guarde o arquivo de backup e a senha no seu gerenciador de senhas:"
    echo "  ${P12}"
    echo "Se o certificado se perder, a próxima versão fará todos os usuários concederem Full Disk Access novamente."
else
    echo "O certificado foi importado, mas não apareceu como identidade de assinatura disponível."
    exit 1
fi
