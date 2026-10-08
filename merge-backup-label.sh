#!/usr/bin/env bash
#
# merge-backup-label.sh
#
# Consolida execucoes do vm-backup-label.sh feitas em sessoes separadas,
# uma por cluster. Nao autentica, nao chama oc, nao escreve em cluster nenhum.
# Le somente arquivos locais.
#
set -uo pipefail

LATEST_ONLY=false
OUT="./consolidado-backup-label-$(date +%Y%m%d-%H%M%S)"
DIRS=()

usage() {
  cat <<EOF
Uso: $(basename "$0") [opcoes] [DIR ...]

  --latest-only   Mantem so a execucao mais recente de cada cluster
  --out DIR       Diretorio de saida  (default: ${OUT})
  -h, --help      Esta ajuda

DIR e onde ficam os diretorios de execucao do vm-backup-label.sh.
Sem DIR usa o diretorio corrente. A busca vai ate 4 niveis.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --latest-only) LATEST_ONLY=true; shift ;;
    --out)         OUT="$2"; shift 2 ;;
    -h|--help)     usage; exit 0 ;;
    -*) echo "Argumento desconhecido: $1" >&2; usage; exit 1 ;;
    *)  DIRS+=("$1"); shift ;;
  esac
done
[[ ${#DIRS[@]} -gt 0 ]] || DIRS=(".")

for d in "${DIRS[@]}"; do
  [[ -d "$d" ]] || { echo "diretorio inexistente: $d" >&2; exit 1; }
done

mkdir -p "$OUT"
CONSOL="$OUT/consolidado.csv"
ORFAOS="$OUT/pvc-rotulado-sem-vm.csv"
PROV="$OUT/execucoes.txt"

echo "cluster,namespace,vm,volume,pvc,pv,origem,label_vm,label_pvc,label_pv,esperado,status_pvc,status_pv,pv_phase,label_dv,status_dv" > "$CONSOL"
echo "cluster,namespace,pvc,label,phase" > "$ORFAOS"

mapfile -t RUNS < <(find "${DIRS[@]}" -maxdepth 4 -name relatorio.csv -printf '%T@\t%p\n' \
                    2>/dev/null | sort -rn | cut -f2)
[[ ${#RUNS[@]} -gt 0 ]] || {
  echo "nenhum relatorio.csv encontrado em: ${DIRS[*]}" >&2
  echo "cada execucao do vm-backup-label.sh cria um diretorio com esse arquivo." >&2
  exit 1
}

declare -A SEEN=()
USED=0
{
  echo "# execucoes consolidadas, mais recentes primeiro"
  printf '%-12s %-32s %-17s %-11s %s\n' USO CLUSTER QUANDO TIPO ORIGEM
} > "$PROV"

for r in "${RUNS[@]}"; do
  dir="$(dirname "$r")"
  cl="$(awk -F',' 'NR==2 {print $1; exit}' "$r")"
  [[ -n "$cl" ]] || cl="desconhecido"
  when="$(date -r "$r" +'%Y-%m-%d %H:%M')"
  if [[ -f "$dir/undo.sh" ]]; then tipo="correcao"; else tipo="auditoria"; fi

  if [[ "$LATEST_ONLY" == true && -n "${SEEN[$cl]:-}" ]]; then
    printf '%-12s %-32s %-17s %-11s %s\n' "ignorada" "$cl" "$when" "$tipo" "$r" >> "$PROV"
    continue
  fi
  if [[ -n "${SEEN[$cl]:-}" ]]; then
    printf '%-12s %-32s %-17s %-11s %s\n' "DUPLICADA" "$cl" "$when" "$tipo" "$r" >> "$PROV"
  else
    printf '%-12s %-32s %-17s %-11s %s\n' "ok" "$cl" "$when" "$tipo" "$r" >> "$PROV"
  fi
  SEEN[$cl]=1
  USED=$((USED+1))
  tail -n +2 "$r" >> "$CONSOL"
  orf="$dir/pvc-rotulado-sem-vm.tsv"
  [[ -s "$orf" ]] && awk -F'\t' -v cl="$cl" '{print cl","$1","$2","$3","$4}' "$orf" >> "$ORFAOS"
done

DISTINTOS=$(awk -F',' 'NR>1 {print $1}' "$CONSOL" | sort -u | wc -l)

{
cat "$PROV"
echo
echo "Clusters distintos: ${DISTINTOS}   Execucoes usadas: ${USED}"
if [[ "$LATEST_ONLY" != true && "$USED" -gt "$DISTINTOS" ]]; then
  echo "AVISO: ha cluster com mais de uma execucao no consolidado, linhas duplicadas."
  echo "Use --latest-only para manter so a mais recente de cada um."
fi
echo
echo "Cada linha reflete o estado no momento em que aquela execucao coletou o"
echo "inventario. Execucao do tipo correcao mostra o estado ANTES da correcao."

echo
echo "== Resumo por cluster =="
printf '%-30s %8s %8s %8s %8s\n' CLUSTER MIS_PVC MIS_PV MIS_DV OUTROS
awk -F',' 'NR>1 {k[$1]=1; a[$1"|"$12]++; b[$1"|"$13]++; d[$1"|"$16]++}
  END {
    for (x in k) {
      out = a[x"|PVC_NOT_FOUND"]+0 + a[x"|VM_UNLABELED"]+0 \
            + a[x"|DIVERGENT"]+0 + b[x"|DIVERGENT"]+0 + d[x"|DIVERGENT"]+0 \
            + b[x"|PV_NOT_FOUND"]+0 + b[x"|PV_NOT_BOUND"]+0 + b[x"|PV_TERMINATING"]+0 \
            + d[x"|DV_NOT_FOUND"]+0
      printf "%-30s %8d %8d %8d %8d\n", x,
        a[x"|MISSING"]+0, b[x"|MISSING"]+0, d[x"|MISSING"]+0, out
    }
  }' "$CONSOL" | sort

echo
echo "== Total por status =="
printf '  %-16s %8s %8s %8s\n' STATUS PVC PV DV
awk -F',' 'NR>1 {a[$12]++; b[$13]++; d[$16]++; k[$12]=1; k[$13]=1; k[$16]=1}
  END {for (s in k) if (s != "-") printf "  %-16s %8d %8d %8d\n", s, a[s]+0, b[s]+0, d[s]+0}' "$CONSOL" | sort

PEND=$(awk -F',' 'NR>1 && ($12=="MISSING" || $13=="MISSING" || $16=="MISSING")' "$CONSOL" | wc -l)
echo
echo "== Discos com pendencia (MISSING em PVC, PV ou DV): ${PEND} =="
[[ "$PEND" -gt 0 ]] && awk -F',' 'NR>1 && ($12=="MISSING" || $13=="MISSING" || $16=="MISSING") {c[$1]++} END {for (x in c) printf "  %-30s %d\n", x, c[x]}' "$CONSOL" | sort

echo
echo "== PV em Terminating =="
awk -F',' 'NR>1 && $13=="PV_TERMINATING" {print "  "$1"  "$6"  (pvc "$2"/"$5")"}' "$CONSOL" | sort -u

echo
echo "== VMs sem o label, decisao manual =="
awk -F',' 'NR>1 && $12=="VM_UNLABELED" {print "  "$1"  "$2"/"$3}' "$CONSOL" | sort -u

echo
echo "== PVC rotulado sem VM: $(( $(wc -l < "$ORFAOS") - 1 )) =="
echo "  detalhe em ${ORFAOS}"
} | tee "$OUT/resumo.txt"

echo
echo "Saida: ${OUT}"
