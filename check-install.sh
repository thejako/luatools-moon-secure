#!/usr/bin/env bash
# ============================================================================
#  luatools-moon-secure — Installation & Configuration Checker
# ============================================================================
#  Verifies that all components of the secure LuaTools stack are properly
#  installed and configured:
#    - Native Steam bootstrap and environment
#    - Steam accounts and active session detection
#    - Security Gatekeeper configuration and wrappers
#    - Account isolation policy (Authorized vs Clean user behavior)
#    - SLSsteam, Lumen binary and LuaTools plugin files
#    - Optional components (CloudRedirect, Game Mode integration)
#
#  Usage:
#    curl -fsSL https://raw.githubusercontent.com/thejako/luatools-moon-secure/main/check-install.sh | bash
#    bash check-install.sh
# ============================================================================

set -uo pipefail

# ----------------------------------------------------------------------------
# Localization (English, Español, Português)
# ----------------------------------------------------------------------------
LANG_IS_ES=0
LANG_IS_PT=0
detect_language() {
	local l="${LC_ALL:-${LC_MESSAGES:-${LANG:-}}}"
	case "$l" in
		es*|*_ES*)       LANG_IS_ES=1; LANG_IS_PT=0 ;;
		pt*|*_BR*|*_PT*) LANG_IS_ES=0; LANG_IS_PT=1 ;;
		*)               LANG_IS_ES=0; LANG_IS_PT=0 ;;
	esac
}
detect_language

L() {
	if [ "$LANG_IS_ES" = 1 ] && [ -n "${3:-}" ]; then
		printf '%s' "$3"
	elif [ "$LANG_IS_PT" = 1 ] && [ -n "${2:-}" ]; then
		printf '%s' "$2"
	else
		printf '%s' "$1"
	fi
}

# ----------------------------------------------------------------------------
# Palette / Formatting
# ----------------------------------------------------------------------------
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-dumb}" != "dumb" ]; then
	BOLD=$'\033[1m'; DIM=$'\033[2m'; NC=$'\033[0m'
	MOON=$'\033[38;5;153m'; NIGHT=$'\033[38;5;75m'; HALO=$'\033[38;5;231m'
	GREEN=$'\033[38;5;114m'; YELLOW=$'\033[38;5;221m'; RED=$'\033[38;5;203m'
	CYAN=$'\033[38;5;81m'
else
	BOLD=""; DIM=""; NC=""
	MOON=""; NIGHT=""; HALO=""
	GREEN=""; YELLOW=""; RED=""; CYAN=""
fi

# Counters
TOTAL_CHECKS=0
PASSED_CHECKS=0
WARNINGS=0
FAILURES=0

check_pass() {
	TOTAL_CHECKS=$((TOTAL_CHECKS + 1))
	PASSED_CHECKS=$((PASSED_CHECKS + 1))
	echo -e "  ${GREEN}✓ PASS${NC}  $1"
	[ -n "${2:-}" ] && echo -e "         ${DIM}$2${NC}"
}

check_warn() {
	TOTAL_CHECKS=$((TOTAL_CHECKS + 1))
	WARNINGS=$((WARNINGS + 1))
	echo -e "  ${YELLOW}⚠ WARN${NC}  $1"
	[ -n "${2:-}" ] && echo -e "         ${YELLOW}$2${NC}"
}

check_fail() {
	TOTAL_CHECKS=$((TOTAL_CHECKS + 1))
	FAILURES=$((FAILURES + 1))
	echo -e "  ${RED}✗ FAIL${NC}  $1"
	[ -n "${2:-}" ] && echo -e "         ${RED}$2${NC}"
}

check_info() {
	echo -e "  ${CYAN}ℹ INFO${NC}  $1"
	[ -n "${2:-}" ] && echo -e "         ${DIM}$2${NC}"
}

print_header() {
	echo ""
	echo -e "${MOON}${BOLD}"
	echo "┌─────────────────────────────────────────────────────────┐"
	printf "│     ${HALO}◯${NC}${MOON}${BOLD}  slsteammoon · LuaTools Secure Verification      │\n"
	echo "└─────────────────────────────────────────────────────────┘"
	echo -e "${NC}"
}

print_section() {
	echo ""
	echo -e "${NIGHT}─────────────────────────────────────────────────────────${NC}"
	echo -e "${NIGHT}${BOLD}❯ $1${NC}"
	echo -e "${NIGHT}─────────────────────────────────────────────────────────${NC}"
}

# ----------------------------------------------------------------------------
# Discovery Helpers
# ----------------------------------------------------------------------------
find_steam_root() {
	if [ -n "${GATEKEEPER_STEAM_ROOT:-}" ] && [ -d "$GATEKEEPER_STEAM_ROOT" ]; then
		printf '%s' "$GATEKEEPER_STEAM_ROOT"
		return 0
	fi
	local link_target
	link_target="$(readlink -e -q "$HOME/.steam/steam" 2>/dev/null || readlink -f "$HOME/.steam/steam" 2>/dev/null || true)"
	local candidates=(
		"$HOME/.steam/steam"
		"$HOME/.local/share/Steam"
		${link_target:+"$link_target"}
		"$HOME/.steam/root"
		"$HOME/.steam/debian-installation"
	)
	local c
	for c in "${candidates[@]}"; do
		if [ -f "$c/config/loginusers.vdf" ]; then
			printf '%s' "$c"
			return 0
		fi
	done
	for c in "${candidates[@]}"; do
		if [ -d "$c/config" ]; then
			printf '%s' "$c"
			return 0
		fi
	done
	if [ -d "$HOME/.steam/steam" ]; then
		printf '%s' "$HOME/.steam/steam"
		return 0
	fi
	printf '%s' "$HOME/.local/share/Steam"
}

find_loginusers_vdf() {
	local sr
	sr="$(find_steam_root)"
	if [ -f "$sr/config/loginusers.vdf" ]; then
		printf '%s' "$sr/config/loginusers.vdf"
		return 0
	fi
	local candidates=(
		"$HOME/.steam/steam/config/loginusers.vdf"
		"$HOME/.local/share/Steam/config/loginusers.vdf"
		"$HOME/.steam/root/config/loginusers.vdf"
		"$HOME/.steam/debian-installation/config/loginusers.vdf"
	)
	local c
	for c in "${candidates[@]}"; do
		if [ -f "$c" ]; then
			printf '%s' "$c"
			return 0
		fi
	done
	local found
	found="$(find "$HOME/.steam" "$HOME/.local/share/Steam" -maxdepth 3 -name "loginusers.vdf" -type f 2>/dev/null | head -n1)"
	if [ -n "$found" ] && [ -f "$found" ]; then
		printf '%s' "$found"
		return 0
	fi
	return 1
}

list_steam_accounts() {
	local vdf="$1"
	[ -f "$vdf" ] || return 1
	awk '
		/^[[:space:]]*"[0-9]+"/ {
			if (id != "") {
				print id "|" acc "|" persona "|" recent
			}
			id = $1; gsub(/[\r"]/, "", id)
			acc = ""; persona = ""; recent = "0"
		}
		tolower($0) ~ /"accountname"/ {
			acc = $0
			sub(/^[[:space:]]*"[Aa][Cc][Cc][Oo][Uu][Nn][Tt][Nn][Aa][Mm][Ee]"[[:space:]]+"/, "", acc)
			sub(/"[\r[:space:]]*$/, "", acc)
		}
		tolower($0) ~ /"personaname"/ {
			persona = $0
			sub(/^[[:space:]]*"[Pp][Ee][Rr][Ss][Oo][Nn][Aa][Nn][Aa][Mm][Ee]"[[:space:]]+"/, "", persona)
			sub(/"[\r[:space:]]*$/, "", persona)
		}
		tolower($0) ~ /"mostrecent"[[:space:]]+"1"/ {
			recent = "1"
		}
		END {
			if (id != "") {
				print id "|" acc "|" persona "|" recent
			}
		}
	' "$vdf" 2>/dev/null
}

get_active_steamid() {
	local vdf="$1"
	[ -f "$vdf" ] || return 1
	local res
	res="$(awk '
		/^[[:space:]]*"[0-9]+"/ {
			current_id = $1
			gsub(/[\r"]/, "", current_id)
			count++
			if (first_id == "") first_id = current_id
		}
		tolower($0) ~ /"mostrecent"[[:space:]]+"?1"?/ {
			active_id = current_id
		}
		tolower($0) ~ /"timestamp"/ {
			ts = $0
			sub(/^[[:space:]]*"[Tt][Ii][Mm][Ee][Ss][Tt][Aa][Mm][Pp]"[[:space:]]+"?[^0-9]*/, "", ts)
			sub(/[^0-9].*$/, "", ts)
			if (ts + 0 > max_ts) {
                max_ts = ts + 0
                latest_id = current_id
            }
		}
		END {
			if (active_id != "") {
				print active_id
			} else if (latest_id != "") {
				print latest_id
			} else if (count == 1) {
				print first_id
			}
		}
	' "$vdf" 2>/dev/null | tr -d '\r[:space:]')"
	[ -n "$res" ] || return 1
	printf '%s' "$res"
}

# ============================================================================
# Check 1: System & Native Steam
# ============================================================================
check_system_steam() {
	print_section "$(L "1. System & Native Steam Environment" \
	                   "1. Ambiente do Sistema e Steam Nativa" \
	                   "1. Entorno del Sistema y Steam Nativo")"

	# Arch check
	local arch
	arch="$(uname -m 2>/dev/null || echo "unknown")"
	if [ "$arch" = "x86_64" ]; then
		check_pass "$(L "Architecture is x86_64 (${arch})" \
		                "Arquitetura é x86_64 (${arch})" \
		                "La arquitectura es x86_64 (${arch})")"
	else
		check_fail "$(L "Unsupported architecture: ${arch} (expected x86_64)" \
		                "Arquitetura não suportada: ${arch} (esperado x86_64)" \
		                "Arquitectura no soportada: ${arch} (se esperaba x86_64)")"
	fi

	# Native Steam binary
	local steam_bin=""
	local candidate
	for candidate in /usr/bin/steam /usr/games/steam /usr/local/bin/steam; do
		if [ -x "$candidate" ]; then
			steam_bin="$candidate"
			break
		fi
	done
	if [ -z "$steam_bin" ] && command -v steam >/dev/null 2>&1; then
		steam_bin="$(command -v steam)"
	fi

	if [ -n "$steam_bin" ]; then
		check_pass "$(L "Native Steam binary found at ${steam_bin}" \
		                "Binário da Steam nativa encontrado em ${steam_bin}" \
		                "Binario de Steam nativo encontrado en ${steam_bin}")"
	else
		check_fail "$(L "Native Steam binary not found in standard paths" \
		                "Binário da Steam nativa não encontrado nos caminhos padrão" \
		                "Binario de Steam nativo no encontrado en rutas estándar")"
	fi

	# Steam root & bootstrap
	local link="$HOME/.steam/steam"
	local root
	root="$(readlink -e -q "$link" 2>/dev/null || true)"
	if [ -L "$link" ] && [ -n "$root" ] && [ -f "$root/steam.sh" ]; then
		check_pass "$(L "Steam bootstrap symlink valid: ${link} -> ${root}" \
		                "Link simbólico do bootstrap da Steam válido: ${link} -> ${root}" \
		                "Enlace simbólico del bootstrap de Steam válido: ${link} -> ${root}")"
	elif [ -d "$HOME/.local/share/Steam" ] && [ -f "$HOME/.local/share/Steam/steam.sh" ]; then
		check_pass "$(L "Steam data directory found: ~/.local/share/Steam" \
		                "Diretório de dados da Steam encontrado: ~/.local/share/Steam" \
		                "Directorio de datos de Steam encontrado: ~/.local/share/Steam")"
	else
		check_warn "$(L "Steam bootstrap symlink (~/.steam/steam) not fully initialized" \
		                "Link de inicialização da Steam (~/.steam/steam) não inicializado completamente" \
		                "Enlace de inicialización de Steam (~/.steam/steam) no inicializado completamente")" \
		           "$(L "Launch native Steam once if you haven't opened it yet." \
		                "Abra a Steam nativa uma vez se ainda não o fez." \
		                "Abre Steam nativo una vez si aún no lo has abierto.")"
	fi

	# loginusers.vdf
	local vdf
	vdf="$(find_loginusers_vdf || true)"
	if [ -n "$vdf" ] && [ -f "$vdf" ]; then
		check_pass "$(L "Steam login configuration found at ${vdf}" \
		                "Configuração de login da Steam encontrada em ${vdf}" \
		                "Configuración de cuentas de Steam encontrada en ${vdf}")"

		local accounts
		accounts="$(list_steam_accounts "$vdf")"
		if [ -n "$accounts" ]; then
			local count=0
			while IFS='|' read -r sid acc persona recent; do
				[ -n "$sid" ] || continue
				count=$((count + 1))
				local rec_mark=""
				[ "$recent" = "1" ] && rec_mark=" [ACTIVE / RECENT]"
				check_info "$(printf "Steam Account #%d: %s (%s) — ID: %s%s" "$count" "${persona:-Unknown}" "${acc:-User}" "$sid" "$rec_mark")"
			done <<< "$accounts"
		fi
	else
		check_warn "$(L "loginusers.vdf not found (no Steam accounts logged in yet)" \
		                "loginusers.vdf não encontrado (nenhuma conta Steam conectada ainda)" \
		                "loginusers.vdf no encontrado (ninguna cuenta de Steam iniciada aún)")"
	fi
}

# ============================================================================
# Check 2: Security Gatekeeper Configuration
# ============================================================================
check_security_gatekeeper() {
	print_section "$(L "2. Security Gatekeeper & Account Isolation" \
	                   "2. Gatekeeper de Segurança e Isolamento de Contas" \
	                   "2. Gatekeeper de Seguridad y Aislamiento de Cuentas")"

	local cfg_file="${XDG_CONFIG_HOME:-$HOME/.config}/luatools-secure/config.json"
	local auth_id="" auth_persona="" auth_account=""

	if [ -f "$cfg_file" ]; then
		if command -v jq >/dev/null 2>&1; then
			if jq -e . "$cfg_file" >/dev/null 2>&1; then
				auth_id="$(jq -r '.authorized_steamid // empty' "$cfg_file" 2>/dev/null)"
				auth_persona="$(jq -r '.authorized_persona_name // empty' "$cfg_file" 2>/dev/null)"
				auth_account="$(jq -r '.authorized_account_name // empty' "$cfg_file" 2>/dev/null)"
				auth_id="$(printf '%s' "$auth_id" | tr -d '\r[:space:]')"
				check_pass "$(L "Gatekeeper config.json exists and is valid JSON" \
				                "Arquivo config.json do Gatekeeper existe e é um JSON válido" \
				                "El archivo config.json del Gatekeeper existe y es JSON válido")"
			else
				check_fail "$(L "Gatekeeper config.json contains malformed JSON!" \
				                "config.json do Gatekeeper contém JSON corrompido!" \
				                "¡config.json del Gatekeeper contiene JSON malformado!")"
			fi
		else
			auth_id="$(sed -n 's/.*"authorized_steamid"[[:space:]]*:[[:space:]]*"\([0-9]*\)".*/\1/p' "$cfg_file" 2>/dev/null | head -n1)"
			auth_id="$(printf '%s' "$auth_id" | tr -d '\r[:space:]')"
			check_pass "$(L "Gatekeeper config.json exists" \
			                "Arquivo config.json do Gatekeeper existe" \
			                "El archivo config.json del Gatekeeper existe")"
		fi

		if [ -n "$auth_id" ]; then
			check_pass "$(L "Authorized SteamID configured: ${auth_id} (${auth_persona:-User})" \
			                "SteamID autorizado configurado: ${auth_id} (${auth_persona:-Usuário})" \
			                "SteamID autorizado configurado: ${auth_id} (${auth_persona:-Usuario})")"
		else
			check_warn "$(L "No authorized SteamID is configured in config.json" \
			                "Nenhum SteamID autorizado configurado no config.json" \
			                "No hay ningún SteamID autorizado configurado en config.json")" \
			           "$(L "All accounts will run 100% clean official Steam." \
			                "Todas as contas rodarão Steam 100% limpa e oficial." \
			                "Todas las cuentas ejecutarán Steam oficial 100% limpia.")"
		fi
	else
		check_fail "$(L "Gatekeeper config missing at ${cfg_file}" \
		                "Configuração do Gatekeeper ausente em ${cfg_file}" \
		                "Falta la configuración del Gatekeeper en ${cfg_file}")"
	fi

	# Gatekeeper wrapper inspection
	local wrapper="$HOME/.local/share/SLSsteam/path/steam"
	local modded="$HOME/.local/share/SLSsteam/path/steam.modded"

	if [ -f "$wrapper" ] && [ -x "$wrapper" ]; then
		if grep -qF "luatools-moon-secure — Gatekeeper" "$wrapper" 2>/dev/null; then
			check_pass "$(L "Gatekeeper wrapper installed at ${wrapper}" \
			                "Wrapper do Gatekeeper instalado em ${wrapper}" \
			                "Wrapper del Gatekeeper instalado en ${wrapper}")"
		else
			check_warn "$(L "Wrapper at ${wrapper} is missing the Gatekeeper security header" \
			                "O wrapper em ${wrapper} não tem o cabeçalho de segurança do Gatekeeper" \
			                "El wrapper en ${wrapper} no tiene la cabecera de seguridad del Gatekeeper")"
		fi
	else
		check_fail "$(L "Gatekeeper wrapper missing or not executable at ${wrapper}" \
		                "Wrapper do Gatekeeper ausente ou não executável em ${wrapper}" \
		                "Falta el wrapper del Gatekeeper o no es ejecutable en ${wrapper}")"
	fi

	if [ -f "$modded" ] && [ -x "$modded" ]; then
		check_pass "$(L "Modded wrapper backup found at ${modded}" \
		                "Wrapper modificado de backup encontrado em ${modded}" \
		                "Wrapper modificado de respaldo encontrado en ${modded}")"
	else
		check_warn "$(L "Modded wrapper missing at ${modded}" \
		                "Wrapper modificado ausente em ${modded}" \
		                "Falta el wrapper modificado en ${modded}")"
	fi

	local watcher="$HOME/.local/share/SLSsteam/path/gatekeeper-watcher.sh"
	if [ -f "$watcher" ] && [ -x "$watcher" ]; then
		check_pass "$(L "Gatekeeper session watcher deployed at ${watcher}" \
		                "Watcher de sessão do Gatekeeper instalado em ${watcher}" \
		                "Vigilante de sesión del Gatekeeper instalado en ${watcher}")"
	fi

	# Active Account & Simulation
	local vdf
	vdf="$(find_loginusers_vdf || true)"
	if [ -n "$vdf" ] && [ -f "$vdf" ]; then
		local active_id
		active_id="$(get_active_steamid "$vdf" || true)"
		if [ -n "$active_id" ]; then
			check_info "$(L "Currently active Steam account in loginusers.vdf: ${active_id}" \
			                "Conta Steam atualmente ativa no loginusers.vdf: ${active_id}" \
			                "Cuenta de Steam actualmente activa en loginusers.vdf: ${active_id}")"

			if [ -n "$auth_id" ] && [ "$active_id" = "$auth_id" ]; then
				check_pass "$(L "ACTIVE USER MATCHES AUTHORIZED ACCOUNT -> MODDED MODE" \
				                "USUÁRIO ATIVO CORRESPONDE À CONTA AUTORIZADA -> MODO MODIFICADO" \
				                "EL USUARIO ACTIVO COINCIDE CON LA CUENTA AUTORIZADA -> MODO MODIFICADO")" \
				           "$(L "Next Steam launch will load SLSsteam, Lumen sidecar & LuaTools." \
				                "A próxima inicialização da Steam carregará SLSsteam, Lumen e LuaTools." \
				                "El próximo inicio de Steam cargará SLSsteam, Lumen y LuaTools.")"
			else
				check_warn "$(L "ACTIVE USER IS CLEAN / UNAUTHORIZED -> CLEAN MODE (MODS DISABLED)" \
				                "USUÁRIO ATIVO É LIMPO / NÃO AUTORIZADO -> MODO LIMPO (MODS DESATIVADOS)" \
				                "EL USUARIO ACTIVO ES LIMPIO / NO AUTORIZADO -> MODO LIMPIO (MODS DESACTIVADOS)")" \
				           "$(L "Steam runs 100% clean official (no LuaTools). Active user (${active_id}) != authorized (${auth_id:-none})." \
				                "A Steam rodará 100% limpa (sem LuaTools). Usuário ativo (${active_id}) != autorizado (${auth_id:-nenhum})." \
				                "Steam se ejecutará 100% limpio (sin LuaTools). Usuario activo (${active_id}) != autorizado (${auth_id:-ninguno}).")"
			fi
		else
			check_info "$(L "Could not determine active Steam session (no MostRecent account)" \
			                "Não foi possível determinar a sessão ativa da Steam (sem conta MostRecent)" \
			                "No se pudo determinar la sesión activa de Steam (sin cuenta MostRecent)")"
		fi
	fi
}

# ============================================================================
# Check 3: SLSsteam Runtime Stack
# ============================================================================
check_slssteam() {
	print_section "$(L "3. SLSsteam Runtime Stack" \
	                   "3. Runtime do SLSsteam" \
	                   "3. Runtime de SLSsteam")"

	local sls_dir="$HOME/.local/share/SLSsteam"
	if [ -d "$sls_dir" ]; then
		check_pass "$(L "SLSsteam directory present at ${sls_dir}" \
		                "Diretório do SLSsteam presente em ${sls_dir}" \
		                "Directorio de SLSsteam presente en ${sls_dir}")"
	else
		check_fail "$(L "SLSsteam directory missing at ${sls_dir}" \
		                "Diretório do SLSsteam ausente em ${sls_dir}" \
		                "Falta el directorio de SLSsteam en ${sls_dir}")"
	fi

	local sls_cfg="$HOME/.config/SLSsteam/config.yaml"
	if [ -f "$sls_cfg" ]; then
		check_pass "$(L "SLSsteam config.yaml present at ${sls_cfg}" \
		                "config.yaml do SLSsteam presente em ${sls_cfg}" \
		                "config.yaml de SLSsteam presente en ${sls_cfg}")"
		local dis_cloud
		dis_cloud="$(grep -iE '^[[:space:]]*DisableCloud:' "$sls_cfg" 2>/dev/null | head -n1 || echo "")"
		if [ -n "$dis_cloud" ]; then
			check_info "SLSsteam ${dis_cloud}"
		fi
	else
		check_warn "$(L "SLSsteam config.yaml missing at ${sls_cfg}" \
		                "config.yaml do SLSsteam ausente em ${sls_cfg}" \
		                "Falta config.yaml de SLSsteam en ${sls_cfg}")"
	fi
}

# ============================================================================
# Check 4: Lumen Bridge & LuaTools Plugin
# ============================================================================
check_lumen_plugin() {
	print_section "$(L "4. Lumen Bridge & LuaTools Plugin" \
	                   "4. Lumen Bridge e Plugin LuaTools" \
	                   "4. Puente Lumen y Plugin LuaTools")"

	local lumen_bin="$HOME/.local/share/Lumen/lumen"
	if [ -f "$lumen_bin" ] && [ -x "$lumen_bin" ]; then
		# Verify ELF header (64-bit ELF)
		local elf_magic
		elf_magic="$(od -An -tx1 -N5 "$lumen_bin" 2>/dev/null | tr -d ' \n' || echo "")"
		if [ "$elf_magic" = "7f454c4602" ]; then
			check_pass "$(L "Lumen binary valid 64-bit ELF executable at ${lumen_bin}" \
			                "Binário do Lumen é um executável ELF 64-bit válido em ${lumen_bin}" \
			                "El binario de Lumen es un ejecutable ELF de 64 bits válido en ${lumen_bin}")"
		else
			check_warn "$(L "Lumen binary exists but ELF magic does not match (${elf_magic})" \
			                "Binário do Lumen existe mas a assinatura ELF difere (${elf_magic})" \
			                "El binario de Lumen existe pero la firma ELF difiere (${elf_magic})")"
		fi
	else
		check_fail "$(L "Lumen binary missing or not executable at ${lumen_bin}" \
		                "Binário do Lumen ausente ou não executável em ${lumen_bin}" \
		                "Falta el binario de Lumen o no es ejecutable en ${lumen_bin}")"
	fi

	local plugin_dir="$HOME/.local/share/Lumen/luatools"
	local plugin_json="$plugin_dir/plugin.json"
	if [ -d "$plugin_dir" ]; then
		if [ -f "$plugin_json" ]; then
			local p_name p_ver
			if command -v jq >/dev/null 2>&1; then
				p_name="$(jq -r '.name // empty' "$plugin_json" 2>/dev/null)"
				p_ver="$(jq -r '.version // empty' "$plugin_json" 2>/dev/null)"
			else
				p_name="luatools"
				p_ver="$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$plugin_json" 2>/dev/null | head -n1)"
			fi
			check_pass "$(L "LuaTools plugin installed: ${p_name} v${p_ver:-unknown} at ${plugin_dir}" \
			                "Plugin LuaTools instalado: ${p_name} v${p_ver:-desconhecida} em ${plugin_dir}" \
			                "Plugin LuaTools instalado: ${p_name} v${p_ver:-desconocida} en ${plugin_dir}")"
		else
			check_warn "$(L "plugin.json missing in ${plugin_dir}" \
			                "plugin.json ausente em ${plugin_dir}" \
			                "Falta plugin.json en ${plugin_dir}")"
		fi
	else
		check_warn "$(L "LuaTools plugin directory missing at ${plugin_dir}" \
		                "Diretório do plugin LuaTools ausente em ${plugin_dir}" \
		                "Falta el directorio del plugin LuaTools en ${plugin_dir}")" \
		           "$(L "If you installed with --noplugin, this is expected." \
		                "Se instalou com --noplugin, isso é esperado." \
		                "Si instalaste con --noplugin, esto es esperado.")"
	fi
}

# ============================================================================
# Check 5: Optional Components (CloudRedirect & Game Mode)
# ============================================================================
check_optionals() {
	print_section "$(L "5. Optional Integrations" \
	                   "5. Integrações Opcionais" \
	                   "5. Integraciones Opcionales")"

	# CloudRedirect hook
	local cr_so="$HOME/.local/share/CloudRedirect/cloud_redirect.so"
	if [ -f "$cr_so" ]; then
		check_pass "$(L "CloudRedirect hook deployed at ${cr_so}" \
		                "Hook do CloudRedirect instalado em ${cr_so}" \
		                "Hook de CloudRedirect instalado en ${cr_so}")"
		if command -v python3 >/dev/null 2>&1 && python3 -c "
import sys
try:
    with open(sys.argv[1], 'rb') as f:
        d = f.read()
    sys.exit(0 if b'\x68\x22\x27\x00\x00\x56\xff\x97\x0c\x24\x00\x00\x83\xc4\x0c\x6a\x01\x6a\x34\x56' in d else 1)
except Exception:
    sys.exit(1)
" "$cr_so" 2>/dev/null; then
			check_pass "$(L "CloudRedirect hook: OneDrive 302 redirect fix active" \
			                "Hook do CloudRedirect: correção de redirecionamento 302 do OneDrive ativa" \
			                "Hook de CloudRedirect: corrección de redirecciones 302 de OneDrive activa")"
		fi
	else
		check_info "$(L "CloudRedirect hook is not installed (optional cloud saves disabled)" \
		                "Hook do CloudRedirect não está instalado (cloud saves opcionais desativados)" \
		                "El hook de CloudRedirect no está instalado (guardado en la nube opcional desactivado)")"
	fi

	# Game Mode systemd drop-in
	local gm_dropin=""
	local c_gm
	for c_gm in \
		"$HOME/.config/systemd/user/steam-launcher.service.d/slsteammoon.conf" \
		"$HOME/.config/gamescope-session-plus/sessions.d/steam" \
		"$HOME/.config/gamescope-session/sessions.d/steam" \
		"$HOME/.config/systemd/user/gamescope-session.service.d/slsteam-moon.conf"; do
		if [ -f "$c_gm" ]; then
			gm_dropin="$c_gm"
			break
		fi
	done
	if [ -n "$gm_dropin" ]; then
		check_pass "$(L "Game Mode service override active at ${gm_dropin}" \
		                "Override do serviço Game Mode ativo em ${gm_dropin}" \
		                "Override del servicio Game Mode activo en ${gm_dropin}")"
	else
		check_info "$(L "Game Mode service override not present (Desktop mode or unconfigured)" \
		                "Override do serviço Game Mode não presente (Modo desktop ou não configurado)" \
		                "Override del servicio Game Mode no presente (Modo escritorio o no configurado)")"
	fi
}

# ============================================================================
# Summary & Exit
# ============================================================================
print_summary() {
	echo ""
	echo -e "${NIGHT}─────────────────────────────────────────────────────────${NC}"
	echo -e "${BOLD}$(L "Verification Summary" "Resumo da Verificação" "Resumen de Verificación")${NC}"
	echo -e "${NIGHT}─────────────────────────────────────────────────────────${NC}"
	echo -e "  $(L "Total checks performed:" "Total de testes:" "Total de comprobaciones: ")  ${TOTAL_CHECKS}"
	echo -e "  ${GREEN}$(L "Passed:" "Aprovados:" "Exitosas:")            ${PASSED_CHECKS}${NC}"
	echo -e "  ${YELLOW}$(L "Warnings:" "Avisos:" "Avisos:")          ${WARNINGS}${NC}"
	echo -e "  ${RED}$(L "Failures:" "Falhas:" "Fallos:")            ${FAILURES}${NC}"
	echo ""

	if [ "$FAILURES" -eq 0 ]; then
		echo -e "${GREEN}${BOLD}✓ $(L "All core checks passed! The secure LuaTools stack is healthy." \
		                           "Todos os testes principais passaram! O stack seguro está saudável." \
		                           "¡Todas las comprobaciones principales pasaron! El stack seguro está en perfecto estado.")${NC}"
		echo ""
		exit 0
	else
		echo -e "${RED}${BOLD}✗ $(L "Some critical components failed verification." \
		                           "Alguns componentes críticos falharam na verificação." \
		                           "Algunos componentes críticos no superaron la verificación.")${NC}"
		echo -e "  $(L "Consider re-running install.sh to repair missing or broken files:" \
		               "Considere executar novamente o install.sh para reparar arquivos ausentes:" \
		               "Considera volver a ejecutar install.sh para reparar archivos faltantes:")"
		echo -e "    ${GREEN}curl -fsSL https://raw.githubusercontent.com/thejako/luatools-moon-secure/main/install.sh | bash${NC}"
		echo ""
		exit 1
	fi
}

main() {
	print_header
	check_system_steam
	check_security_gatekeeper
	check_slssteam
	check_lumen_plugin
	check_optionals
	print_summary
}

main "$@"
