#!/usr/bin/env bash
set -e

REPO_RAW="${REPO_RAW:-https://raw.githubusercontent.com/itcaat/mtproto-installer/main}"
INSTALL_DIR="${INSTALL_DIR:-$(pwd)/mtproxy-data}"
FAKE_DOMAIN="${FAKE_DOMAIN:-1c.ru}"
TELEMT_INTERNAL_PORT="${TELEMT_INTERNAL_PORT:-1234}"
LISTEN_PORT="${LISTEN_PORT:-443}"

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

rerun_cmd() {
	if [[ "$0" == *bash* ]] || [[ "$0" == -* ]]; then
		echo "curl -sSL https://raw.githubusercontent.com/itcaat/mtproto-installer/main/install.sh | bash"
	else
		local dir
		dir="$(cd "$(dirname "$0")" && pwd)"
		echo "bash ${dir}/$(basename "$0")"
	fi
}

check_docker() {
	if command -v docker &>/dev/null; then
		if docker info &>/dev/null 2>&1; then
			info "Docker доступен."
			return 0
		fi
		echo ""
		warn "Docker установлен, но текущий пользователь не в группе docker."
		echo ""
		echo "Выполните команду (добавление в группу и применение):"
		echo -e "  ${GREEN}sudo usermod -aG docker \$USER && newgrp docker${NC}"
		echo ""
		echo "Затем запустите этот скрипт снова:"
		echo -e "  ${GREEN}$(rerun_cmd)${NC}"
		echo ""
		exit 1
	fi
	info "Установка Docker..."
	curl -fsSL https://get.docker.com | sh
	if ! docker info &>/dev/null 2>&1; then
		echo ""
		warn "Docker установлен. Нужно добавить пользователя в группу docker."
		echo ""
		echo "Выполните команду:"
		echo -e "  ${GREEN}sudo usermod -aG docker \$USER && newgrp docker${NC}"
		echo ""
		echo "Затем запустите этот скрипт снова:"
		echo -e "  ${GREEN}$(rerun_cmd)${NC}"
		echo ""
		exit 1
	fi
}

is_port_in_use() {
	local port="$1"
	if command -v ss &>/dev/null; then
		ss -tuln 2>/dev/null | grep -qE "[.:]${port}[[:space:]]"
		return $?
	fi
	if command -v nc &>/dev/null; then
		nc -z 127.0.0.1 "$port" 2>/dev/null
		return $?
	fi
	return 1
}

prompt_port() {
	local suggested=443
	if is_port_in_use 443; then
		warn "Порт 443 занят."
		suggested=1443
		while true; do
			if [[ -t 0 ]]; then
				echo -n "Введите порт [${suggested}]: "
				read -r input
				[[ -z "$input" ]] && input=$suggested
			else
				LISTEN_PORT=$suggested
				return
			fi
			if [[ "$input" =~ ^[0-9]+$ ]] && (( input >= 1 && input <= 65535 )); then
				if is_port_in_use "$input"; then
					warn "Порт ${input} тоже занят, выберите другой."
				else
					LISTEN_PORT=$input
					return
				fi
			else
				warn "Введите число от 1 до 65535."
			fi
		done
	else
		if [[ -t 0 ]]; then
			echo -n "Порт для прокси [443]: "
			read -r input
			[[ -n "$input" ]] && input="$input" || input=443
			while true; do
				if [[ "$input" =~ ^[0-9]+$ ]] && (( input >= 1 && input <= 65535 )); then
					if is_port_in_use "$input"; then
						warn "Порт ${input} занят, выберите другой."
						echo -n "Введите порт: "
						read -r input
					else
						LISTEN_PORT=$input
						return
					fi
				else
					warn "Введите число от 1 до 65535."
					echo -n "Введите порт [443]: "
					read -r input
					[[ -z "$input" ]] && input=443
				fi
			done
		fi
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
	sed "s/443:443/${LISTEN_PORT}:443/" "${INSTALL_DIR}/docker-compose.yml" > "${INSTALL_DIR}/docker-compose.yml.tmp" && mv "${INSTALL_DIR}/docker-compose.yml.tmp" "${INSTALL_DIR}/docker-compose.yml"
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
	LINK="tg://proxy?server=${SERVER_IP}&port=${LISTEN_PORT}&secret=${LONG_SECRET}"
	echo ""
	echo -e "${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
	echo -e "${GREEN}║  Ссылка для Telegram (Fake TLS)                         ║${NC}"
	echo -e "${GREEN}╚══════════════════════════════════════════════════════════╝${NC}"
	echo ""
	echo -e "  ${GREEN}${LINK}${NC}"
	echo ""
	echo "  Сохраните ссылку и не публикуйте её публично."
	echo ""
	echo "  Данные установки: ${INSTALL_DIR}"
	echo "  Логи:            cd ${INSTALL_DIR} && docker compose logs -f"
	echo "  Остановка:       cd ${INSTALL_DIR} && docker compose down"
	echo ""
}

main() {
	[[ "${INSTALL_DIR}" != /* ]] && INSTALL_DIR="$(pwd)/${INSTALL_DIR}"
	check_docker
	prompt_port
	prompt_fake_domain
	download_and_configure
	run_compose
	print_link
}

main "$@"
