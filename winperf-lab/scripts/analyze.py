#!/usr/bin/env python3
"""Le um ou mais results.csv do measure-ttfb.ps1 e imprime uma tabela Markdown
com mediana + IQR por (stage, type). Descarta o run 1 de cada stage (cold compile inicial).

Uso: python3 analyze.py results.csv [outro.csv ...]
"""
import csv, sys, statistics, collections

rows = collections.defaultdict(list)
for fn in (sys.argv[1:] or ["results.csv"]):
    with open(fn, newline="") as f:
        for row in csv.DictReader(f):
            try:
                run = int(row["run"]); ms = float(row["ms"])
            except (ValueError, KeyError):
                continue
            if run == 1:      # descarta a primeira rodada (compilacao inicial do ASP.NET)
                continue
            if row.get("status") not in (None, "", "200"):
                # so conta respostas 200; -1 = timeout/erro
                if row.get("status") != "200":
                    continue
            rows[(row["stage"], row["type"])].append(ms)

def iqr(vals):
    if len(vals) < 2:
        return 0.0
    q = statistics.quantiles(vals, n=4)   # [q1, q2, q3]
    return q[2] - q[0]

print("| stage | type | n | mediana (ms) | IQR (ms) | min | max |")
print("|---|---|---|---|---|---|---|")
for (stage, typ) in sorted(rows):
    v = rows[(stage, typ)]
    print(f"| {stage} | {typ} | {len(v)} | {statistics.median(v):.0f} | {iqr(v):.0f} | {min(v):.0f} | {max(v):.0f} |")
