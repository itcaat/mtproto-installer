#!/usr/bin/env bash
set -e

REPO_RAW="${REPO_RAW:-https://raw.githubusercontent.com/itcaat/mtproto-installer/main}"
INSTALL_DIR="${INSTALL_DIR:-$(pwd)/mtproxy-data}"
FAKE_DOMAIN="${FAKE_DOMAIN:-1c.ru}"
TELEMT_INTERNAL_PORT="${TELEMT_INTERNAL_PORT:-1234}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()   { echo -e "${RED}[ERR]${NC} $*"; exit 1; }

fetch() {
	local url="$1"
	local dest="$2"
	if ! curl -fsSL "$url" -o "$dest"; then
		err "Не удалось загрузить: $url"
	fi
}

check_docker() {
	if command -v docker &>/dev/null; then
		if docker info &>/dev/null 2>&1; then
			info "Docker доступен."
			return 0
		fi
		warn "Docker установлен, но текущий пользователь не в группе docker. Запустите: sudo usermod -aG docker \$USER && newgrp docker"
		err "Или запустите этот скрипт с sudo."
	fi
	info "Установка Docker..."
	curl -fsSL https://get.docker.com | sh
	if ! docker info &>/dev/null 2>&1; then
		err "После установки Docker выполните: sudo usermod -aG docker \$USER && newgrp docker (или перелогиньтесь), затем снова запустите скрипт."
	fi
}

prompt_fake_domain() {
	if [[ -n "${FAKE_DOMAIN_FROM_ENV}" ]]; then
		FAKE_DOMAIN="${FAKE_DOMAIN_FROM_ENV}"
		return
	fi
	if [[ -t 0 ]]; then
		echo -n "Домен для маскировки Fake TLS [${FAKE_DOMAIN}]: "
		read -r input
		[[ -n "$input" ]] && FAKE_DOMAIN="$input"
	fi
}

generate_secret() {
	openssl rand -hex 16
}

download_and_configure() {
	info "Загрузка файлов из ${REPO_RAW} ..."
	mkdir -p "${INSTALL_DIR}/traefik/dynamic" "${INSTALL_DIR}/traefik/static"

	fetch "${REPO_RAW}/docker-compose.yml" "${INSTALL_DIR}/docker-compose.yml"
	fetch "${REPO_RAW}/traefik/dynamic/tcp.yml" "${INSTALL_DIR}/traefik/dynamic/tcp.yml"
	fetch "${REPO_RAW}/telemt.toml.example" "${INSTALL_DIR}/telemt.toml.example"

	SECRET=$(generate_secret)

	sed -e "s/ПОДСТАВЬТЕ_32_СИМВОЛА_HEX/${SECRET}/g" \
	    -e "s/tls_domain = \"1c.ru\"/tls_domain = \"${FAKE_DOMAIN}\"/g" \
	    "${INSTALL_DIR}/telemt.toml.example" > "${INSTALL_DIR}/telemt.toml"
	rm -f "${INSTALL_DIR}/telemt.toml.example"
	info "Создан ${INSTALL_DIR}/telemt.toml (домен маскировки: ${FAKE_DOMAIN})"

	local tcp_yml="${INSTALL_DIR}/traefik/dynamic/tcp.yml"
	sed -e "s/1c\.ru/${FAKE_DOMAIN}/g" \
	    -e "s/telemt:1234/telemt:${TELEMT_INTERNAL_PORT}/g" \
	    "$tcp_yml" > "${tcp_yml}.tmp" && mv "${tcp_yml}.tmp" "$tcp_yml"
	info "Настроен Traefik: SNI ${FAKE_DOMAIN} -> telemt:${TELEMT_INTERNAL_PORT} (TLS passthrough)"

	printf '%s' "$SECRET" > "${INSTALL_DIR}/.secret"
}

run_compose() {
	cd "${INSTALL_DIR}"
	docker compose pull -q 2>/dev/null || true
	docker compose up -d
	info "Контейнеры запущены."
}

print_link() {
	local SECRET TLS_DOMAIN DOMAIN_HEX LONG_SECRET SERVER_IP LINK
	SECRET=$(cat "${INSTALL_DIR}/.secret" 2>/dev/null | tr -d '\n\r')
	[[ -z "$SECRET" ]] && err "Секрет не найден в ${INSTALL_DIR}/.secret"

	TLS_DOMAIN=$(grep -E '^[[:space:]]*tls_domain[[:space:]]*=' "${INSTALL_DIR}/telemt.toml" \
		| head -n1 | sed -E 's/.*=[[:space:]]*"([^"]+)".*/\1/')
	[[ -z "$TLS_DOMAIN" ]] && err "tls_domain не найден в ${INSTALL_DIR}/telemt.toml"

	DOMAIN_HEX=$(printf '%s' "$TLS_DOMAIN" | od -An -tx1 | tr -d ' \n')
	if [[ "$SECRET" =~ ^[0-9a-fA-F]{32}$ ]]; then
		LONG_SECRET="ee${SECRET}${DOMAIN_HEX}"
	else
		LONG_SECRET="$SECRET"
	fi

	SERVER_IP=$(curl -s --connect-timeout 3 ifconfig.me 2>/dev/null || echo "YOUR_SERVER_IP")
	LINK="tg://proxy?server=${SERVER_IP}&port=443&secret=${LONG_SECRET}"
	echo ""
	echo -e "${GREEN}--- Ссылка для Telegram ---${NC}"
	echo "${LINK}"
	echo ""
	echo "Сохраните ссылку и не публикуйте её публично."
	echo "Данные установки: ${INSTALL_DIR}"
	echo "Логи: cd ${INSTALL_DIR} && docker compose logs -f"
	echo "Остановка: cd ${INSTALL_DIR} && docker compose down"
}

main() {
	[[ "${INSTALL_DIR}" != /* ]] && INSTALL_DIR="$(pwd)/${INSTALL_DIR}"
	check_docker
	prompt_fake_domain
	download_and_configure
	run_compose
	print_link
}

main "$@"
