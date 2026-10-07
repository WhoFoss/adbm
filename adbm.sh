#!/usr/bin/env bash

fecha=$'\033[m'
branco=$'\033[37;1m'
vermelho=$'\033[31;1m'
amarelo=$'\033[33;1m'

# Dependências
for dep in adb nc; do
    type -P "$dep" &>/dev/null || {
        printf '%s[ERRO]%s falta o %s\n' "$vermelho" "$fecha" "$dep"
        exit 1
    }
done

# Prefixo da rede
prefixo=$(hostname -I 2>/dev/null | tr ' ' '\n' | grep -v '127\.' | grep -v ':' | head -1 | cut -d. -f1-3)
[[ -z "$prefixo" ]] && prefixo=$(ifconfig 2>/dev/null | awk '/inet / && !/127\./ {print $2}' | head -1 | cut -d. -f1-3)
[[ -z "$prefixo" ]] && {
    printf '%s[ERRO]%s nao detectei a rede\n' "$vermelho" "$fecha"
    exit 1
}

# Escaneia
printf '%sEscaneando %s.1..254:5555...%s' "$amarelo" "$prefixo" "$fecha"

resultados=$(seq 1 254 | xargs -P 50 -I{} bash -c "
    timeout 0.3 nc -z -w1 $prefixo.{} 5555 2>/dev/null && echo $prefixo.{}
" | sort -t. -k4 -n)

printf '\r\033[K'

[[ -z "$resultados" ]] && {
    printf '%s[AVISO]%s nenhum dispositivo encontrado\n' "$amarelo" "$fecha"
    exit 0
}

total=$(printf '%s\n' "$resultados" | wc -l)

printf '%sEncontrados: %d%s\n' "$branco" "$total" "$fecha"
while IFS= read -r ip; do
    printf '  %sIP:%s %s%s%s\n' "$branco" "$fecha" "$branco" "$ip" "$fecha"
done <<< "$resultados"
