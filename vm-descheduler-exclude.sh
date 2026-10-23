#!/usr/bin/env bash
# vm-descheduler-exclude.sh
#
# Tira VMs específicas do balanceamento automático do descheduler
# (perfil KubeVirtRelieveAndMigrate), sem impedir live migration de
# manutenção (drain continua migrando).
#
# Como funciona: grava a annotation
#   descheduler.alpha.kubernetes.io/prefer-no-eviction: "true"
# em spec.template.metadata.annotations de cada VM. O KubeVirt leva a
# annotation pro pod virt-launcher em execução na hora (sem restart), e ela
# se mantém em migrações e reinícios. No perfil KubeVirtRelieveAndMigrate o
# operador configura essa annotation como obrigatória (noEvictionPolicy:
# Mandatory). Em qualquer outro perfil ela é ignorada.
#
# Uso:
#   ./vm-descheduler-exclude.sh plan   lista.txt     só mostra o que faria (padrão)
#   ./vm-descheduler-exclude.sh apply  lista.txt     aplica
#   ./vm-descheduler-exclude.sh verify lista.txt     confere template e pod
#   ./vm-descheduler-exclude.sh undo   lista.txt     remove a annotation
#
# Alvo (segundo argumento):
#   lista.txt          batch: todas as VMs da lista
#   --vm NOME          individual: uma VM só (pode repetir: --vm a --vm b)
#
# Opção -i (com apply/undo): pergunta s/N antes de alterar cada VM.
#
# Exemplos:
#   ./vm-descheduler-exclude.sh apply --vm minha-vm
#   ./vm-descheduler-exclude.sh apply lista.txt -i
#
# lista.txt: um nome de VM por linha. Só a primeira coluna é lida (aceita a
# exportação do vSphere com estado e DRS nas outras colunas). Linhas vazias e
# começadas com # são ignoradas. Maiúsculas e minúsculas tanto faz.
#
# Opcional: OC_CONTEXT=<contexto> pra apontar o cluster.

set -uo pipefail

KEY="descheduler.alpha.kubernetes.io/prefer-no-eviction"
JKEY='descheduler\.alpha\.kubernetes\.io/prefer-no-eviction'
OC=(oc --request-timeout=30s)
[ -n "${OC_CONTEXT:-}" ] && OC+=(--context "$OC_CONTEXT")

die() { echo "ERRO: $*" >&2; exit 1; }

uso() { sed -n '2,36p' "$0"; exit 1; }
modo=${1:-}; shift || true
case "$modo" in plan|apply|verify|undo) ;; *) uso ;; esac

nomes=(); interativo=0; lista=""
while [ $# -gt 0 ]; do
  case "$1" in
    --vm) [ -n "${2:-}" ] || die "--vm precisa de um nome"; nomes+=("$2"); shift 2 ;;
    -i) interativo=1; shift ;;
    -*) die "opção desconhecida: $1" ;;
    *) [ -z "$lista" ] || die "só uma lista por vez"; lista=$1; shift ;;
  esac
done
if [ -n "$lista" ]; then
  [ -f "$lista" ] || die "lista não encontrada: $lista"
  while read -r linha; do nomes+=("$linha"); done < "$lista"
fi
[ ${#nomes[@]} -gt 0 ] || uso
if [ $interativo -eq 1 ] && [ ! -t 0 ]; then die "-i precisa de terminal interativo"; fi

echo "== perfil do descheduler"
perfis=$("${OC[@]}" get kubedescheduler cluster -n openshift-kube-descheduler-operator -o jsonpath='{.spec.profiles}' 2>/dev/null)
if [ -z "$perfis" ]; then
  echo "AVISO: nenhum KubeDescheduler 'cluster' encontrado. A annotation fica gravada, mas não há descheduler pra respeitá-la."
elif ! echo "$perfis" | grep -q KubeVirtRelieveAndMigrate; then
  echo "AVISO: o descheduler usa $perfis, sem KubeVirtRelieveAndMigrate. Nesses perfis a annotation é IGNORADA (noEvictionPolicy Preferred)."
else
  echo "ok: $perfis"
fi
echo

inv=$(mktemp); trap 'rm -f "$inv"' EXIT
"${OC[@]}" get vm -A -o jsonpath='{range .items[*]}{.metadata.namespace} {.metadata.name} {.status.printableStatus}{"\n"}{end}' > "$inv" \
  || die "não consegui listar as VMs"

alvos=(); faltando=(); ambiguos=()
for linha in "${nomes[@]}"; do
  nome=$(printf '%s\n' "$linha" | awk '{print $1}' | tr '[:upper:]' '[:lower:]')
  [ -z "$nome" ] && continue
  case "$nome" in \#*) continue ;; esac
  achados=$(awk -v n="$nome" '$2==n{print $1"/"$2" "$3}' "$inv")
  qtd=$(printf '%s' "$achados" | grep -c . || true)
  if [ "$qtd" -eq 0 ]; then faltando+=("$nome")
  elif [ "$qtd" -gt 1 ]; then ambiguos+=("$nome: $(echo "$achados" | awk '{print $1}' | tr '\n' ' ')")
  else alvos+=("$achados")
  fi
done

echo "== resumo da lista"
echo "encontradas: ${#alvos[@]}   não encontradas: ${#faltando[@]}   ambíguas: ${#ambiguos[@]}"
[ ${#faltando[@]} -gt 0 ] && { echo "-- não encontradas:"; printf '   %s\n' "${faltando[@]}"; }
[ ${#ambiguos[@]} -gt 0 ] && { echo "-- ambíguas (mesmo nome em mais de um namespace, NÃO serão tocadas):"; printf '   %s\n' "${ambiguos[@]}"; }
echo

pod_anot() {
  local ns=$1 vm=$2 p
  p=$("${OC[@]}" get pods -n "$ns" -l "vm.kubevirt.io/name=$vm" --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
  [ -z "$p" ] && { echo "sem-pod"; return; }
  v=$("${OC[@]}" get pod "$p" -n "$ns" -o jsonpath="{.metadata.annotations.$JKEY}" 2>/dev/null)
  echo "${v:-ausente}"
}

falhas=0
echo "== $modo"
for a in "${alvos[@]}"; do
  ref=${a%% *}; estado=${a#* }; ns=${ref%%/*}; vm=${ref##*/}
  atual=$("${OC[@]}" get vm "$vm" -n "$ns" -o jsonpath="{.spec.template.metadata.annotations.$JKEY}" 2>/dev/null)
  if [ $interativo -eq 1 ] && { [ "$modo" = apply ] || [ "$modo" = undo ]; }; then
    if { [ "$modo" = apply ] && [ "$atual" != "true" ]; } || { [ "$modo" = undo ] && [ "$atual" = "true" ]; }; then
      read -r -p "  $modo em $ref ($estado)? [s/N] " resp
      resp=${resp//$'\r'/}
      case "$resp" in s|S|sim|y|Y) ;; *) echo "  $ref: pulada"; continue ;; esac
    fi
  fi
  case "$modo" in
    plan)
      if [ "$atual" = "true" ]; then echo "  $ref ($estado): já protegida"; else echo "  $ref ($estado): vai receber a annotation"; fi ;;
    apply)
      if [ "$atual" = "true" ]; then echo "  $ref: já protegida"; continue; fi
      if "${OC[@]}" patch vm "$vm" -n "$ns" --type merge -p "{\"spec\":{\"template\":{\"metadata\":{\"annotations\":{\"$KEY\":\"true\"}}}}}" >/dev/null 2>&1; then
        echo "  $ref: aplicada"
      else echo "  $ref: FALHOU"; falhas=$((falhas+1)); fi ;;
    verify)
      pa=$(pod_anot "$ns" "$vm")
      if [ "$atual" = "true" ] && { [ "$pa" = "true" ] || [ "$pa" = "sem-pod" ]; }; then
        echo "  $ref ($estado): ok (template=true, pod=$pa)"
      else echo "  $ref ($estado): PROBLEMA (template=${atual:-ausente}, pod=$pa)"; falhas=$((falhas+1)); fi ;;
    undo)
      if [ "$atual" != "true" ]; then echo "  $ref: não estava protegida"; continue; fi
      if "${OC[@]}" patch vm "$vm" -n "$ns" --type json -p "[{\"op\":\"remove\",\"path\":\"/spec/template/metadata/annotations/${KEY//\//~1}\"}]" >/dev/null 2>&1; then
        echo "  $ref: removida"
      else echo "  $ref: FALHOU"; falhas=$((falhas+1)); fi ;;
  esac
done
echo
[ "$modo" = "plan" ] && echo "Nada foi alterado. Rode com 'apply' pra aplicar."
[ $falhas -gt 0 ] && { echo "Terminou com $falhas falha(s)."; exit 2; }
exit 0
