#!/bin/bash

# =============================================================================
# Escaneador ADB na rede local
# =============================================================================

# -----------------------------------------------------------------------------
# Dependências
# -----------------------------------------------------------------------------
declare -A dep_pkg=(
    ["adb"]="android-tools"
    ["nc"]="netcat-openbsd"
)

for dep in "${!dep_pkg[@]}"; do
    if ! command -v "$dep" &>/dev/null; then
        echo "[ERRO] Dependencia ausente: $dep"
        echo "Instale com: pkg install ${dep_pkg[$dep]}"
        exit 1
    fi
done

# -----------------------------------------------------------------------------
# Cores
# -----------------------------------------------------------------------------
if [ -t 1 ]; then
    PURPLE='\033[0;35m'
    BLUE='\033[0;34m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    CYAN='\033[0;36m'
    RED='\033[0;31m'
    BOLD='\033[1m'
    NC='\033[0m'
else
    PURPLE='' BLUE='' GREEN='' YELLOW='' CYAN='' RED='' BOLD='' NC=''
fi

# -----------------------------------------------------------------------------
# Largura do terminal
# -----------------------------------------------------------------------------
_term_width() {
    local w=0
    if command -v tput &>/dev/null; then w=$(tput cols 2>/dev/null); fi
    if [[ -z "$w" || "$w" -le 0 ]]; then w=$(stty size 2>/dev/null | awk '{print $2}'); fi
    if [[ -z "$w" || "$w" -le 0 ]]; then w=$COLUMNS; fi
    if [[ -z "$w" || "$w" -le 0 ]]; then w=80; fi
    echo "$w"
}

# -----------------------------------------------------------------------------
# Repete um caractere N vezes
# -----------------------------------------------------------------------------
_repeat() {
    local char="$1" n="$2"
    printf "%${n}s" | tr ' ' "$char"
}

# -----------------------------------------------------------------------------
# Caixa de título centralizado (ASCII)
# +------ Titulo ------+
# -----------------------------------------------------------------------------
_box_titulo() {
    local msg="$1"
    local color="${2:-$CYAN}"
    local tw; tw=$(_term_width)
    local inner=$(( tw - 2 ))
    local mlen=${#msg}
    local pad=$(( (inner - mlen) / 2 ))
    local rpad=$(( inner - mlen - pad ))
    local hline; hline=$(_repeat '-' "$inner")
    printf "%b+%s+%b\n" "$color" "$hline" "$NC"
    printf "%b|%b%${pad}s%b%s%b%${rpad}s%b|%b\n" "$color" "$NC" "" "$BOLD" "$msg" "$NC" "" "$color" "$NC"
    printf "%b+%s+%b\n" "$color" "$hline" "$NC"
}

# -----------------------------------------------------------------------------
# Célula com padding correto (cor separada do printf)
# -----------------------------------------------------------------------------
_cell() {
    local color="$1" text="$2" width="$3"
    local pad=$(( width - ${#text} ))
    [[ $pad -lt 0 ]] && pad=0
    printf "%b%s%b%${pad}s" "$color" "$text" "$NC" ""
}

# -----------------------------------------------------------------------------
# Linha separadora da tabela (ASCII)
# +-------+----+----------+
# -----------------------------------------------------------------------------
_tline() {
    local l="$1" m="$2" r="$3"
    shift 3
    local cols=("$@")
    local line="${CYAN}${l}"
    local i
    for (( i=0; i<${#cols[@]}; i++ )); do
        line+=$(_repeat '-' $(( cols[i] + 2 )))
        (( i < ${#cols[@]} - 1 )) && line+="$m"
    done
    line+="${r}${NC}"
    printf "%b\n" "$line"
}

# -----------------------------------------------------------------------------
# Tabela unificada: HOST | MODELO | STATUS
# Cada host: ip modelo adb_color adb_label
# Exibe [N] antes do IP quando show_index=1
# -----------------------------------------------------------------------------
_print_tabela() {
    local port="$1" show_index="${2:-0}"
    shift 2

    local tw; tw=$(_term_width)

    local col2=16  # MODELO
    local col3=12  # STATUS
    # [N] ocupa 4 chars + 1 espaço = 5 quando show_index=1
    local idx_width=0
    [[ "$show_index" -eq 1 ]] && idx_width=5

    local fixed=$(( col2 + col3 + 10 ))
    local col1=$(( tw - fixed ))
    [[ $col1 -lt 8 ]] && col1=8
    # col1 inclui o prefixo [N], então o IP real ocupa col1-idx_width
    local col1_ip=$(( col1 - idx_width ))
    [[ $col1_ip -lt 4 ]] && col1_ip=4

    _tline "+" "+" "+" "$col1" "$col2" "$col3"

    # Header
    printf "%b|%b " "$CYAN" "$NC"
    _cell "$BOLD" "HOST"   "$col1"
    printf "%b | %b" "$CYAN" "$NC"
    _cell "$BOLD" "MODELO" "$col2"
    printf "%b | %b" "$CYAN" "$NC"
    _cell "$BOLD" "STATUS" "$col3"
    printf "%b |%b\n" "$CYAN" "$NC"

    _tline "+" "+" "+" "$col1" "$col2" "$col3"

    local idx=1
    while [[ $# -ge 4 ]]; do
        local ip="$1" modelo="$2" acolor="$3" alabel="$4"
        shift 4
        modelo="${modelo:0:$col2}"
        alabel="${alabel:0:$col3}"

        printf "%b|%b " "$CYAN" "$NC"
        if [[ "$show_index" -eq 1 ]]; then
            local prefix_idx
            printf -v prefix_idx "[%d] " "$idx"
            local ip_truncado="${ip:0:$col1_ip}"
            local cell_text="${prefix_idx}${ip_truncado}"
            _cell "$GREEN" "$cell_text" "$col1"
        else
            _cell "$GREEN" "${ip:0:$col1}" "$col1"
        fi
        printf "%b | %b" "$CYAN" "$NC"
        _cell "$NC"     "$modelo" "$col2"
        printf "%b | %b" "$CYAN" "$NC"
        _cell "$acolor" "$alabel" "$col3"
        printf "%b |%b\n" "$CYAN" "$NC"
        (( idx++ ))
    done

    _tline "+" "+" "+" "$col1" "$col2" "$col3"
}

# -----------------------------------------------------------------------------
# Detecta prefixo de rede
# -----------------------------------------------------------------------------
_detectar_prefixo_rede() {
    local prefix
    prefix=$(hostname -I 2>/dev/null \
        | tr ' ' '\n' | grep -v '127\.' | grep -v ':' \
        | head -1 | cut -d'.' -f1-3)
    if [[ -z "$prefix" ]]; then
        prefix=$(ifconfig 2>/dev/null \
            | awk '/inet / && !/127\.0\.0\.1/ {print $2}' \
            | head -1 | cut -d'.' -f1-3)
    fi
    echo "$prefix"
}

# -----------------------------------------------------------------------------
# Spinner
# -----------------------------------------------------------------------------
_spinner() {
    local prefix="$1" range="$2" port="$3"
    local frames=('-' '\' '|' '/') i=0
    while true; do
        printf "\r%b[%b%s%b]%b Escaneando %s.%s:%s...%b" \
            "$PURPLE" "$BLUE" "${frames[i]}" "$PURPLE" "$YELLOW" \
            "$prefix" "$range" "$port" "$NC"
        i=$(( (i+1) % 4 ))
        sleep 0.1
    done
}

# -----------------------------------------------------------------------------
# Scan de hosts via nc
# -----------------------------------------------------------------------------
_escanear_hosts() {
    local prefix="$1" start="$2" end="$3" port="$4"
    seq "$start" "$end" | xargs -P 50 -I{} bash -c "
        if timeout 0.3 nc -w1 -z \"${prefix}.{}\" ${port} 2>/dev/null; then
            echo \"${prefix}.{}\"
        fi
    "
}

# -----------------------------------------------------------------------------
# Conectar ADB e pegar modelo
# Saída: "modelo|cor|label"
# -----------------------------------------------------------------------------
_conectar_adb() {
    local ip="$1" port="$2"
    local attempt state res modelo

    for attempt in 1 2; do
        res=$(adb connect "${ip}:${port}" 2>&1)
        state=$(adb devices | awk -v dev="${ip}:${port}" '$1==dev{print $2}')

        if [[ "$state" == "device" ]]; then
            modelo=$(timeout 3 adb -s "${ip}:${port}" shell getprop ro.product.model 2>/dev/null | tr -d '\r')
            [[ -z "$modelo" ]] && modelo="desconhecido"
            echo "${modelo}|${GREEN}|conectado"
            return 0
        elif [[ "$state" == "offline" && $attempt -eq 1 ]]; then
            adb disconnect "${ip}:${port}" &>/dev/null
            sleep 0.4
        else
            echo "desconhecido|${RED}|${state:-sem resposta}"
            return 1
        fi
    done
}

# -----------------------------------------------------------------------------
# Scan principal
# Saída visual: stdout — IPs encontrados: SCAN_FOUND (global)
# -----------------------------------------------------------------------------
SCAN_FOUND=()
SCAN_TABLE=()
scan_adb_rapido() {
    local start="${1:-1}" end="${2:-254}" port="${3:-5555}" show_index="${4:-0}"
    SCAN_FOUND=()
    SCAN_TABLE=()

    local prefix; prefix=$(_detectar_prefixo_rede)
    if [[ -z "$prefix" ]]; then
        printf "%b[ERRO]%b Nao foi possivel detectar a rede.\n" "$RED" "$NC"
        return 1
    fi

    _spinner "$prefix" "${start}-${end}" "$port" &
    local spin_pid=$!
    local results; results=$(_escanear_hosts "$prefix" "$start" "$end" "$port")
    kill "$spin_pid" 2>/dev/null; wait "$spin_pid" 2>/dev/null
    printf "\r\033[K"

    if [[ -z "$results" ]]; then
        printf "%b[AVISO]%b Nenhum dispositivo encontrado.\n" "$YELLOW" "$NC"
        return 1
    fi

    local found=()
    while IFS= read -r ip; do found+=("$ip"); done <<< "$results"

    local table_args=()
    if command -v adb &>/dev/null; then
        local total=${#found[@]} current=0
        for ip in "${found[@]}"; do
            (( current++ ))
            printf "\r%b[ADB]%b Conectando %d/%d: %s...%b" \
                "$BLUE" "$NC" "$current" "$total" "$ip" "$NC"
            local line modelo rcor rlabel
            line=$(_conectar_adb "$ip" "$port")
            IFS='|' read -r modelo rcor rlabel <<< "$line"
            table_args+=("$ip" "$modelo" "$rcor" "$rlabel")
        done
        printf "\r\033[K"
    else
        for ip in "${found[@]}"; do
            table_args+=("$ip" "desconhecido" "$NC" "n/a")
        done
    fi

    echo ""
    _print_tabela "$port" "$show_index" "${table_args[@]}"

    SCAN_FOUND=("${found[@]}")
    SCAN_TABLE=("${table_args[@]}")
}

# -----------------------------------------------------------------------------
# Prompt interativo — seleção por número ou Enter para watch
# -----------------------------------------------------------------------------
_prompt_conexao() {
    local port="$1" start="$2" end="$3"
    shift 3
    local found=("$@")
    local total=${#found[@]}

    while true; do
        local tw; tw=$(_term_width)
        local linha1="-> Escolha o dispositivo (1-${total}) ou Enter para watch"
        local linha2="-> Escolha (1-${total}) ou Enter=watch"

        echo ""
        if (( ${#linha1} <= tw )); then
            printf "\033[100;36m %s \033[0m\n" "$linha1"
        else
            printf "\033[100;36m %s \033[0m\n" "$linha2"
        fi
        printf "%b(CONECTAR)%b > " "$GREEN" "$NC"
        echo -en "\033[?25h"
        read -r escolha
        echo -en "\033[?25l"

        if [[ -z "$escolha" ]]; then
            adb disconnect &>/dev/null
            echo ""
            _watch_loop "$port" "$start" "$end"
            return
        fi

        if ! [[ "$escolha" =~ ^[0-9]+$ ]] || (( escolha < 1 || escolha > total )); then
            printf "%b[ERRO]%b Opcao invalida. Digite um numero entre 1 e %d.\n" "$RED" "$NC" "$total"
            continue
        fi

        local ip_escolhido="${found[$((escolha - 1))]}"

        for ip in "${found[@]}"; do
            if [[ "$ip" != "$ip_escolhido" ]]; then
                adb disconnect "${ip}:${port}" &>/dev/null
            fi
        done
        printf "%b[OK]%b Mantendo conexao com %s:%s\n" "$GREEN" "$NC" "$ip_escolhido" "$port"
        return
    done
}

# -----------------------------------------------------------------------------
# Watch loop — cataloga a cada 10s, volta ao prompt após 2 ciclos
# -----------------------------------------------------------------------------
_watch_loop() {
    local port="${1:-5555}" start="${2:-1}" end="${3:-254}"
    local interval=10 ciclos=0 max_ciclos=2

    while true; do
        adb disconnect &>/dev/null

        clear
        _box_titulo "Monitoramento" "$CYAN"
#        echo ""
        scan_adb_rapido "$start" "$end" "$port" 0
        (( ciclos++ ))
 #       echo ""

        if (( ciclos >= max_ciclos )) && [[ ${#SCAN_FOUND[@]} -gt 0 ]]; then
            ciclos=0
            clear
            _box_titulo "Monitoramento" "$CYAN"
            echo ""
            _print_tabela "$port" 1 "${SCAN_TABLE[@]}"
            _prompt_conexao "$port" "$start" "$end" "${SCAN_FOUND[@]}"
            return
        fi

        printf "%b[WATCH]%b Proximo scan em %ds -- Ctrl+C para sair\n" "$PURPLE" "$NC" "$interval"
        sleep "$interval"
    done
}

# -----------------------------------------------------------------------------
# Ajuda
# -----------------------------------------------------------------------------
_help() {
    _box_titulo "Monitoramento" "$CYAN"
    echo ""
    printf "  %bUso:%b\n"       "$BOLD" "$NC"
    printf "    adbm [opcoes] [inicio] [fim] [porta]\n\n"
    printf "  %bArgumentos:%b\n" "$BOLD" "$NC"
    printf "    inicio     Primeiro host do range  %b(padrao: 1)%b\n"    "$CYAN" "$NC"
    printf "    fim        Ultimo host do range    %b(padrao: 254)%b\n"  "$CYAN" "$NC"
    printf "    porta      Porta ADB               %b(padrao: 5555)%b\n" "$CYAN" "$NC"
    echo ""
    printf "  %bOpcoes:%b\n" "$BOLD" "$NC"
    printf "    %b-w, --watch%b    Reescaneia a cada 10s, Ctrl+C para sair\n" "$GREEN" "$NC"
    printf "    %b-h, --help%b     Exibe esta mensagem\n" "$GREEN" "$NC"
    echo ""
    printf "  %bExemplos:%b\n" "$BOLD" "$NC"
    printf "    adbm\n"
    printf "    adbm 1 100\n"
    printf "    adbm 1 254 5555\n"
    printf "    adbm --watch\n"
    printf "    adbm -w 1 100 5555\n"
    echo ""
}

# =============================================================================
# Entry point
# =============================================================================
WATCH_MODE=0
ARGS=()
for arg in "$@"; do
    case "$arg" in
        --watch|-w) WATCH_MODE=1 ;;
        --help|-h)  _help; exit 0 ;;
        *)          ARGS+=("$arg") ;;
    esac
done

echo -en "\033[?25l"
trap 'echo -en "\033[?12l\033[?25h"' EXIT
trap 'echo -e "\n${YELLOW}[WATCH]${NC} Encerrado."; exit 0' INT

clear
_box_titulo "Monitoramento" "$CYAN"
#echo ""

if [[ "$WATCH_MODE" -eq 1 ]]; then
    _watch_loop "${ARGS[2]:-5555}" "${ARGS[0]:-1}" "${ARGS[1]:-254}"
else
    local_port="${ARGS[2]:-5555}"
    local_start="${ARGS[0]:-1}"
    local_end="${ARGS[1]:-254}"
    scan_adb_rapido "$local_start" "$local_end" "$local_port" 1
    if [[ ${#SCAN_FOUND[@]} -gt 0 ]]; then
        _prompt_conexao "$local_port" "$local_start" "$local_end" "${SCAN_FOUND[@]}"
    fi
fi
